# DIANN_SINGLE_SEARCH — Design Notes

This document captures the in-progress investigation into a bug that prevents the
DIA-NN search path from running when the user supplies only a single MS file
(one `.raw` / `.mzML` / `.d.zip`). It records the root cause, the proposed plan,
the parameter decisions made, and — crucially — the unsolved sub-problem around
producing a Skyline-compatible spectral library for the single-file case. A
future agent should be able to pick this up cold.

---

## 1. Motivation

### 1.1 The bug

When DIA-NN is run with exactly one MS file, the `DIANN_MBR` step
(`modules/diann.nf:249`) fails with:

```
Missing DiaNN precursor report and/or speclib!
```

This happens regardless of the source of the spectral library — Carafe, a
user-supplied `--lib`, or the DIA-NN-predicted library from `DIANN_BUILD_LIB`.

### 1.2 Root cause

The `DIANN_MBR` process invokes DIA-NN with `--use-quant --gen-spec-lib --reanalyse`
on all collected files. With only one file, DIA-NN auto-disables MBR and prints:

```
WARNING: MBR turned off, at least two files are required : 1
```

When MBR is auto-disabled, DIA-NN does **not** produce
`report-lib.parquet.skyline.speclib`. The rename block at `modules/diann.nf:294-303`
hard-codes that filename as required, so it falls through to the explicit error
path.

Concretely, the directory after the failed run contains (e.g., for a Carafe input):

```
043_Ecl-...DIA.mzML
043_Ecl-...DIA.mzML.quant
2022-03-human-uniprot-reviewed-enolase-contam.fasta
carafe_spectral_library.tsv
carafe_spectral_library.tsv.skyline.speclib   <-- input library cache, NOT empirical output
diann.stdout / diann.stderr
report-lib.parquet                            <-- the empirical output library, in parquet form
report.log.txt
report.parquet
report.stats.tsv
```

Note the absence of `report-lib.parquet.skyline.speclib`.

### 1.3 The bigger issue (user's framing)

MBR is "match between runs." With only one run, it's semantically undefined. The
right fix is not to patch the rename block — it's to skip the entire MBR
aggregation step when there's only one MS file.

---

## 2. Workflow Context

The relevant call chain:

- `subworkflows/diann/main.nf` resolves the spectral library and calls
  `diann_full_search` (alias for `diann_search_parallel`).
- `subworkflows/diann/diann_search.nf:43` defines `diann_search_parallel`, which:
  1. Runs `DIANN_QUANT` per file (one invocation per MS file).
  2. Runs `DIANN_MBR` once on all files + their `.quant` outputs.
- Downstream of that, `BLIB_BUILD_LIBRARY` (`modules/diann.nf:326`) consumes
  the speclib + precursor-report and runs `wine BlibBuild` to produce a `.blib`
  for Skyline.
- The `.blib` flows up to `SKYLINE_ADD_LIB` (`modules/skyline.nf:8`), which
  invokes `wine SkylineCmd --add-library-path=...`.

### 2.1 Spectral library always exists upstream

By the time `diann_search_parallel` runs, a library always exists. `subworkflows/diann/main.nf:32-70` has three branches:

- Carafe was run → use Carafe's `.tsv` library.
- `params.spectral_library` is set → convert `.blib`/`.dlib` to `.tsv` if needed.
- Neither → run `DIANN_BUILD_LIB` (predict from FASTA) → `${fasta.baseName}.predicted.speclib`.

So `DIANN_SINGLE_SEARCH` will always receive a library via `--lib`. It does not
need to predict one.

### 2.2 Dead code we will repurpose

- `DIANN_SEARCH` process at `modules/diann.nf:72` — defined but never reachable.
- `diann_search_serial` workflow at `subworkflows/diann/diann_search.nf:7` — defined
  but never invoked (only `diann_search_parallel` is used).

The plan is to rename `DIANN_SEARCH` → `DIANN_SINGLE_SEARCH` and delete
`diann_search_serial`. (The `DIANN_SEARCH` reference inside `workflows/carafe.nf`
is a local include alias for a different process, `CARAFE_DIANN_SEARCH`, and is
unrelated.)

---

## 3. Proposed Plan

### 3.1 Branch on file count inside `diann_search_parallel`

```groovy
ms_files_collected = ms_file_ch.collect()
ms_files_branched  = ms_files_collected.branch {
    single: it.size() == 1
    multi:  it.size() > 1
}

// Multi-file: existing path, unchanged behavior
DIANN_QUANT(ms_files_branched.multi.flatMap { it }, fasta, spectral_library, params.diann.search_params)
DIANN_MBR(ms_files_branched.multi, DIANN_QUANT.out.quant_file.collect(),
          fasta, spectral_library, report_name, mbr_params)

// Single-file: skip MBR entirely
DIANN_SINGLE_SEARCH(ms_files_branched.single, fasta, spectral_library, report_name, single_params)

// Mix outputs from both paths; only one fires per run
quant_files       = DIANN_QUANT.out.quant_file.mix(DIANN_SINGLE_SEARCH.out.quant_files.flatten())
speclib           = DIANN_MBR.out.speclib.mix(DIANN_SINGLE_SEARCH.out.speclib)
precursor_report  = DIANN_MBR.out.precursor_report.mix(DIANN_SINGLE_SEARCH.out.precursor_report)
// ... same mix for stdout/stderr/version/output_file_stats
```

### 3.2 `DIANN_SINGLE_SEARCH` — final parameter set

Decisions made during research:

| Flag                        | Single-file decision | Reason |
|-----------------------------|----------------------|--------|
| `--f <single.mzML>`         | Yes                  | The input file. |
| `--threads`, `--fasta`, `--lib` | Yes              | Standard. |
| `--gen-spec-lib`            | **Keep**             | Downstream `BLIB_BUILD_LIBRARY` needs a library output. |
| `--use-quant`               | **Drop**             | No prior `.quant` files exist (we skip `DIANN_QUANT`). |
| `--reanalyse`               | **Drop**             | This is what enables MBR. Auto-disabled anyway with one file. |
| `--rt-profiling`            | **Drop**             | Only relevant when DIA-NN generates a library from scratch. `DIANN_BUILD_LIB` is the only place that should ever set it. The single-file search is given a library; nothing to profile. |
| `--id-profiling`            | **Drop**             | Redundant with `--rt-profiling` and not needed here. |
| `${params.diann.search_params}` | Yes              | User search params still apply. |

Final shape:

```bash
diann --f <one.mzML> \
      --threads N \
      --fasta <fasta> \
      --lib <upstream_library> \
      --gen-spec-lib \
      ${params.diann.search_params}
```

### 3.3 Maintenance items the fix must include

Per `SPECIFICATION.md` § Project Maintenance Expectations:

- New stub config (suggested name: `test-resources/test-diann-single-file.config`)
  exercising a single-file DIA-NN run.
- Add the new config to the matrix in `.github/workflows/push-stub-run.yml`.
- Update any docs that describe DIA-NN multi-file behavior, if single-file
  becomes user-visible.
- No `nextflow_schema.json` change anticipated (no new params).

---

## 4. The Unsolved Problem: Producing the `.blib` for Skyline

This is the open part of the work. The downstream contract requires a `.blib`
fed into Skyline via `wine SkylineCmd --add-library-path=...`. The current path
is:

```
DIA-NN .skyline.speclib  →  wine BlibBuild  →  .blib  →  SkylineCmd
```

The single-file DIA-NN run does not produce a `*.parquet.skyline.speclib` file,
so this chain breaks at the BlibBuild step.

### 4.1 What's actually in the working directory after a single-file DIA-NN run

| File | What it is |
|------|-----------|
| `report.parquet` | Precursor report (search results). |
| `report-lib.parquet` | The empirical output spectral library, in parquet. |
| `<input_lib>.tsv.skyline.speclib` | DIA-NN's binary cache of the **input** library, written at startup when the input is `.tsv`. **Not** the empirical output. Confirmed by ~6-minute timestamp lag vs. `report-lib.parquet`. Not produced when the input is already a `.speclib` (e.g., `.predicted.speclib`). |

The `<input>.skyline.speclib` cache is a tempting workaround but is semantically
wrong — it's the input library, not the search-refined empirical library — and
isn't even produced for `.predicted.speclib` inputs.

### 4.2 Test matrix executed during research

| Input library | Flags | `report-lib.parquet.skyline.speclib`? |
|---|---|---|
| `.tsv` | `--use-quant --gen-spec-lib --reanalyse` (single file → MBR auto-disabled) | **No** — only `<input>.skyline.speclib` (input cache) + `report-lib.parquet` |
| `.tsv` | `--gen-spec-lib` only | **No** — only `<input>.skyline.speclib` (input cache) + `report-lib.parquet` |
| `.predicted.speclib` | `--gen-spec-lib` only | **No** — only `report-lib.parquet` (no input cache because input was already speclib) |

Inference: `report-lib.parquet.skyline.speclib` is only produced when MBR
actually engages (i.e., 2+ files). No flag combination tested forces it on a
single file.

### 4.3 Things confirmed dead

- **Renaming `report-lib.parquet` to `*.parquet.skyline.speclib`** so BlibBuild
  reads it — BlibBuild does NOT accept parquet input. (User confirmed.)
- **Using `--out-lib report-lib.speclib`** to force speclib output — DIA-NN
  ignores the `.speclib` extension and writes parquet anyway. (User tested.)
- **Using the `<input>.skyline.speclib` sidecar** as the empirical library —
  it's the input cache, not the empirical output, and not produced for
  `.speclib` inputs.

### 4.4 Routes still on the table

**1. `SkylineCmd --add-library-path` accepts a DIA-NN-native format directly.**

If `wine SkylineCmd --add-library-path=...` accepts `.parquet` (or DIA-NN
`.speclib`) directly, the single-file branch can skip `BLIB_BUILD_LIBRARY`
entirely and pass `report-lib.parquet` straight to `SKYLINE_ADD_LIB`. This is
the cleanest possible fix.

**Status:** The user has emailed Skyline support to ask. Awaiting reply.

**2. Parquet → TSV conversion step (most promising active path).**

BlibBuild **does** accept TSV libraries — that's how Carafe-generated and
EncyclopeDIA-converted libraries already flow through. If we can dump
`report-lib.parquet` to TSV, the existing `BLIB_BUILD_LIBRARY` should work.

Two sub-options:

- **2a. Get DIA-NN itself to emit TSV directly.** Worth checking `diann --help`
  for a "library output format" flag (something like `--out-lib-format tsv`). If
  one exists, it's a one-line fix.
- **2b. Add a small `DIANN_LIB_PARQUET_TO_TSV` process.** Lightweight conversion
  using DuckDB or Python+pyarrow. Example with DuckDB:

  ```bash
  duckdb -c "COPY (SELECT * FROM 'report-lib.parquet') TO 'report-lib.tsv' (DELIMITER E'\t', HEADER)"
  ```

  Would need a new container (or piggyback on an existing one if any have
  parquet support).

**Schema caveat for option 2:** before committing to either, verify that the
columns of `report-lib.parquet` match what BlibBuild expects from a DIA-NN
TSV library. Sanity-check by manually converting one parquet file to TSV
(any tool) and feeding it to `wine BlibBuild` to confirm the round-trip works.

**3. DIA-NN re-invocation purely for library conversion.**

Speculative — would call DIA-NN with `--lib report-lib.parquet --gen-spec-lib
--out-lib X.speclib` and no `--f`, expecting a load-and-rewrite. Unknown
whether DIA-NN supports this without an MS file. Given that `--out-lib`
already proved to ignore extensions, this is unlikely to work, but `diann --help`
might show a documented conversion mode.

**4. Force MBR via a flag override.**

Unknown whether DIA-NN has a flag that forces `--reanalyse` to engage even
with one file. If so, we could keep the current MBR pathway as-is and let it
"run" (degenerately) on a single file to get `report-lib.parquet.skyline.speclib`.
Worth a `diann --help` check.

**5. Phantom-file workaround.**

Pass DIA-NN two logical inputs (e.g., a duplicate or a symlink to the same
file) so MBR engages. Ugly; produces meaningless cross-run matching against
itself. Listed only as a last resort.

### 4.5 Recommended order of attack

1. Wait for Skyline support's reply on whether `SkylineCmd` accepts parquet /
   DIA-NN speclib directly (option 1). If yes, that's the fix.
2. While waiting, run `diann --help` and check for any library-output-format
   flag (option 2a) and any "force MBR" flag (option 4).
3. If 1 and 2a both fail, build a small parquet-to-TSV process (option 2b).
   Verify schema compatibility with a manual end-to-end test before committing.

---

## 5. Side Notes Worth Knowing

### 5.1 The `BLIB_BUILD_LIBRARY` rename's purpose is unclear

`modules/diann.nf:344-348` does:

```bash
f=$(echo *.parquet.skyline.speclib)
newf="${f%.parquet.skyline.speclib}-lib.parquet.skyline.speclib"
mv "$f" "$newf"
wine BlibBuild "$newf" "${get_blib_name()}"
```

The comment says it's to "match the parquet file," but the rename adds a `-lib`
token, moving the speclib's name AWAY from matching the precursor report
(`quant.parquet`). If the rename is cargo cult, simplifying it could open up
options. Not blocking but worth checking git history and BlibBuild's actual
file-matching behavior if we revisit this area.

### 5.2 `DIANN_BUILD_LIB` is the *only* place library generation should live

The user was explicit: `DIANN_SINGLE_SEARCH` will never generate a library. It
always receives one from upstream (Carafe / user `params.spectral_library` /
`DIANN_BUILD_LIB`). This is why `--rt-profiling` was dropped from the
single-file flag set.

### 5.3 Profiling flags in the multi-file path are unchanged

The current `diann_search_parallel` always appends `--rt-profiling` (or
`--id-profiling` for the `speclib_only` subset path) in `DIANN_MBR`. This
investigation does **not** change that — `--rt-profiling` stays in `DIANN_MBR`
for the multi-file path. `--id-profiling` was discussed as redundant but the
multi-file path is out of scope for this fix.

### 5.4 No-search and EncyclopeDIA branches are unaffected

This whole line of work is scoped to the DIA-NN search engine. The
EncyclopeDIA, Cascadia, and no-search paths in `workflows/dia_search.nf` are
not touched.

---

## 6. Quick Reference — Files Most Relevant to This Fix

| File | Why it matters |
|------|----------------|
| `subworkflows/diann/diann_search.nf` | Where the file-count branch will be added. |
| `subworkflows/diann/main.nf` | Library resolution upstream of the search. |
| `modules/diann.nf` | Defines `DIANN_QUANT`, `DIANN_MBR`, dead `DIANN_SEARCH` (→ rename to `DIANN_SINGLE_SEARCH`), `BLIB_BUILD_LIBRARY`. |
| `modules/skyline.nf` | `SKYLINE_ADD_LIB` / `wine SkylineCmd --add-library-path` — the actual Skyline ingestion point. |
| `workflows/dia_search.nf` | Calls into `diann()`; routes batch info. |
| `.github/workflows/push-stub-run.yml` | Add the new single-file stub config to the matrix. |
| `test-resources/` | Add a new single-file DIA-NN config here. |
