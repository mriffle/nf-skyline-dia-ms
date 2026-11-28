# Testing nf-skyline-dia-ms

How to test a change to this workflow: which tests to run, how to run them, where the test
data comes from, and how to judge the result. Written for someone (or an agent) on a machine
that has never run the workflow.

Every time, size and count below was measured on 2026-11-27 on one machine: 12 CPUs, 35 GB
RAM, an RTX 4090, Docker Desktop under WSL2, Nextflow 25.10.4. Treat them as a guide to
proportions, not as promises.

Contents: [kinds of test](#1-three-kinds-of-test) ·
[which tests a change needs](#2-which-tests-does-a-change-need) ·
[setup](#3-setup) · [stub tests](#4-stub-tests) · [quoting check](#5-the-quoting-check) ·
[real runs](#6-real-runs) · [comparing against main](#7-comparing-a-change-against-main) ·
[pitfalls](#8-pitfalls) · [known gaps](#9-known-gaps) · [housekeeping](#10-housekeeping)

## 1. Three kinds of test

| Test | What executes | What it can prove | What it cannot prove |
|---|---|---|---|
| **Stub run** (`-stub-run`) | Nextflow and each process's `stub:` block, which only `touch`es files. No tool runs. | The parameters validate, the right branch is chosen, the channels join, the file names one step declares are the ones the next step expects, the startup checks fire, and the Panorama upload plan is what is expected. | Anything about a tool: whether it accepts its arguments, whether it writes the file the process declares, whether a name with a space survives. A wrong `script:` block passes every stub config. |
| **Quoting check** (`test-resources/check-script-quoting.py`) | A static read of `modules/*.nf`. | That process scripts follow the two rules that keep input file names with spaces working (SPECIFICATION.md, "Input File Names"). | Any other mistake in a script. |
| **Real run** | msconvert, DIA-NN, EncyclopeDIA, Cascadia, Carafe, Skyline and the rest, in their containers, on real data. | That each tool accepts what the script gives it and that the published documents and reports are right. | Scale, AWS Batch, SLURM, Panorama upload (see [known gaps](#9-known-gaps)). |

The stub suite is the wiring test and the real runs are the only test of the scripts. Neither
replaces the other.

## 2. Which tests does a change need?

Find the row for what you touched. If you touched several things, the row furthest down
the table applies.

| Tier | You changed | Run | Budget |
|---|---|---|---|
| 0 | Documentation only: `docs/`, `*.md`, comments outside `script:` blocks | `docs/` changed: build the docs ([below](#docs)). Otherwise nothing. | 1 min |
| 1 | Parameters, defaults, the schema, `main.nf` checks, channel wiring, `publishDir`, a `stub:` block, a stub config, the CI file | The quoting check, the stub configs for the branch you touched, then the [whole stub suite](#the-whole-suite-as-ci-runs-it). A schema or default change also needs the config GUI updated and its tests run ([below](#the-config-gui)). | 15 min |
| 2 | One process's `script:` block, its `output:` declarations or `stageAs` (what the tool really writes and reads is invisible to a stub), a helper function that builds shell text, or a container image version | Tier 1, plus **one real run of a scenario that executes that process**, [compared against `main`](#7-comparing-a-change-against-main). Use the [table of processes](#which-scenario-runs-which-process) to pick it. | 30 to 45 min |
| 3 | A search-engine branch, the hand-off between Skyline steps, naming logic that spans several steps, anything that reads DIA-NN output | Tier 1, plus the [core set](#the-core-set) compared against `main` (four runs), plus the scenario for each branch touched. DIA-NN changes need both DIA-NN images. | 1 to 2 h |
| 4 | Input resolution: `get_ms_files`, `get_input_files`, the Panorama or PDC steps, `.d.zip` handling | Tier 1, plus one real scenario per input source touched (PDC, local, Panorama Public, the authenticated Panorama steps, `.d.zip`). Each of those is under a minute except `pdc` (13 min) and `gpf` (20 min). | 30 min to 1 h |

Real-run evidence is expected for every change to a script (tiers 2 to 4): a stub run cannot
show that a tool accepts what the script gives it. It is not expected for tiers 0 and 1.

The budgets assume the [test cache](#the-test-cache) exists. Building it the first time
takes roughly 30 to 40 minutes on a fast connection (an estimate: 13.5 GB of images at the
rate measured here, plus the 13 minute first run) and is not part of any change's budget.

### Rules for scope and reporting

These exist because a small change once took five hours.

1. **Write the plan down before the first real run.** List the processes whose rendered
   script, inputs or outputs your change can alter, and the scenario that executes each. That
   list is the plan; nothing else gets run.
2. **Ask before going over budget.** If the plan needs more runs than the tier's row lists,
   or more time than its budget, send the plan and its cost to the maintainer and wait. The
   same applies when a test result makes you want to add scenarios.
3. **Report early.** Say what you found after the stub suite and again after the first real
   run. Do not hold results until everything has finished.
4. **Do not fix what you were not asked to fix.** A defect that turns up along the way and is
   not caused by your change goes into the addendum of `AUDIT-2026-04-14.md` (what happens,
   where, how to reproduce it) and into your report. Fixing it is a separate decision.
5. **Mind what a script edit costs users.** Any edit inside a `script:` block, even a comment,
   makes a resumed run repeat that step and everything after it. Say in the commit message
   which steps a resumed run will repeat (SPECIFICATION.md, "Changing a process script").
6. **The QC report code is due to be replaced.** Do not write tests for it. If a change
   elsewhere could break it, run the `qc-report` scenario once and stop there.

### Which scenario runs which process

Scenario names are files in `test-resources/real-runs/scenarios/`; `a + b` means both are
passed. They are described in [section 6](#6-real-runs).

| Process (module) | Smallest scenario that executes it |
|---|---|
| `GET_STUDY_METADATA`, `GET_FILE` (pdc) | `pdc`, with an empty download cache ([note](#steps-that-a-cache-hides)) |
| `MSCONVERT_MULTI_BATCH` (shown in logs as `MSCONVERT`: every MS-file path includes it under that name) | `pdc`, `local` or `local-batches`, with an empty mzML cache ([note](#steps-that-a-cache-hides)) |
| `MSCONVERT` itself (used only for a `.raw` Carafe input), `METADATA_TO_SKY_ANNOTATIONS` (only with `pdc.metadata_tsv`) | none; see [known gaps](#9-known-gaps) |
| `UNZIP_DIRECTORY` (shown in logs as `UNZIP_BRUKER_D`) | `bruker-unzip` (extraction only) |
| `DIANN_BUILD_LIB`, `DIANN_QUANT`, `DIANN_MBR`, `BLIB_BUILD_LIBRARY` (diann) | `local`, once as it is (DIA-NN 1.8.1) and once `+ diann-2.3.0` |
| `ENCYCLOPEDIA_BLIB_TO_DLIB`, `ENCYCLOPEDIA_DLIB_TO_TSV` | `local + library-blib` |
| `ENCYCLOPEDIA_SEARCH_FILE`, `ENCYCLOPEDIA_CREATE_ELIB` | `local + encyclopedia`; with narrow-window data `gpf + gpf-encyclopedia` |
| The narrow-window (subset library) part of the DIA-NN branch | `gpf` |
| `CASCADIA_*`, `BLIB_BUILD_LIBRARY` (cascadia) | `cascadia` (`+ cascadia-gpu`) |
| `CARAFE`, `CARAFE_DIANN_SEARCH` (shown in logs as `carafe:DIANN_SEARCH`) | `local + carafe` |
| `SKYLINE_ADD_LIB`, `SKYLINE_IMPORT_MS_FILE`, `SKYLINE_MERGE_RESULTS`, `SKYLINE_RUN_REPORTS` | `local` |
| `SKYLINE_ANNOTATE_DOCUMENT`, `ANNOTATION_TSV_TO_CSV` | `local + metadata`, or `pdc` |
| `VALIDATE_LOCAL_METADATA` | `local + metadata` |
| `SKYLINE_MINIMIZE_DOCUMENT` | `local + metadata + minimize` |
| Per-batch documents | `pdc + pdc-batches`, or `local-batches` |
| `PANORAMA_PUBLIC_GET_MS_FILE_LIST`, `PANORAMA_PUBLIC_GET_MS_FILE` | `panorama-public` (one file), or `gpf` |
| `PANORAMA_GET_MS_FILE_LIST`, `PANORAMA_GET_MS_FILE` | `panorama-auth` |
| `PANORAMA_GET_FILE` (shown in logs under an alias, here `PANORAMA_GET_SPECTRAL_LIBRARY`) | `gpf + gpf-encyclopedia` (it downloads the library) |
| QC report: `MERGE_REPORTS`, `FILTER_IMPUTE_NORMALIZE`, `GENERATE_QC_QMD`, `RENDER_QC_REPORT` | `local + qc-report`. The other QC processes (batch report, table export, gene reports) are not run by any scenario. |
| A user-supplied Skyline template; `skyline.skip` | `local + template`; `local + skip-skyline` |
| `CALCULATE_MD5`, `WRITE_FILE_STATS`, run details | any scenario |
| `UPLOAD_FILE`, `IMPORT_SKYLINE`, `PANORAMA_GET_SKYR_FILE`, the AWS steps | none; see [known gaps](#9-known-gaps) |

## 3. Setup

Needed for everything: `git`, Nextflow, a Java it runs on, Python 3 with PyYAML.
Needed for real runs as well: Docker, `curl`, `zip`, `unzip`, and the usual GNU tools
(`awk`, `sed`, `md5sum`, `sha256sum`).

Nothing in this guide sends personal details anywhere, and nothing should: do not put the
maintainer's or your own name, email address or project names into a request to an outside
service. UniProt asks automated clients to identify themselves with a contact address; the
download here is one small request and deliberately sends none.

```bash
# Java: Nextflow 24.10 (the oldest version CI tests) does not run on Java newer than 22.
# CI pins Java 21, which every version in the matrix supports. Use the same.
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64     # wherever a JDK 21 is installed

# Nextflow: any launcher will do; NXF_VER picks the version a command runs.
curl -s https://get.nextflow.io | bash                  # then put ./nextflow on PATH

# Real runs only: where the test cache lives (section 6), and a shorthand used below.
export NFDIA_TEST_HOME="$HOME/nf-skyline-dia-ms-test"
R=test-resources/real-runs
```

With Java 25, `NXF_VER=24.10.5 nextflow run ...` stops with `Project config file is
malformed`, and `.nextflow.log` shows `Unsupported class file major version 69`. Commands in this guide are run from the root of
the repository unless they say otherwise.

## 4. Stub tests

### One config

```bash
export NXF_SECRETS_FILE=/tmp/nf-stub-secrets.json
printf '[{"name": "PANORAMA_API_KEY", "value": "ci-stub-not-a-real-key"}]\n' > "$NXF_SECRETS_FILE"
chmod 600 "$NXF_SECRETS_FILE"

nextflow run . -stub-run -c test-resources/test-diann.config -c test-resources/ci.config
rm -rf work .nextflow .nextflow.log* results reports .nf-cache      # clean up afterwards
```

- **`-c test-resources/ci.config` always goes last.** It turns Docker off, lifts the CPU
  check that would reject `cpus 8` tasks on a small machine, and moves the two cache
  directories off `/data`.
- **The secrets file is isolated on purpose.** Nextflow will not start a task that declares
  `secret 'PANORAMA_API_KEY'` unless the secret exists, even in a stub run. Pointing
  `NXF_SECRETS_FILE` at a throw-away file supplies a placeholder without touching your real
  secrets.
- A stub run takes about 10 seconds. Nextflow 26.04 rejects booleans given on the command
  line (`--slack.enabled true` arrives as a string); set them in an extra `-c` file.

### The whole suite, as CI runs it

`.github/workflows/push-stub-run.yml` is the suite: 42 positive configs (each followed by the
upload-manifest check), 16 negative cases that must fail with a given message, 3 Slack cases
that must succeed with a given warning, all on Nextflow 24.10.5, 25.10.4 and 26.04.0, plus the
quoting check. That is 184 jobs.

```bash
test-resources/run-stub-suite.py                      # everything: all three versions
test-resources/run-stub-suite.py --versions 25.10.4   # one version, while iterating
test-resources/run-stub-suite.py --only pdc --only batch --keep-failed
```

The script reads the job list from the CI file, so it cannot drift from CI, and gives each
job what CI gives it: the placeholder `PANORAMA_API_KEY` for the positive jobs only, the
Slack secret for the Slack jobs. Each job runs in its own copy of the working tree with its
own secrets file, so nothing lands in your working tree and your real secrets are not read.
`--jobs N` sets how many run at once (default: half the CPUs, at most 6). `--keep-failed`
keeps the copy of a failed job, with `nextflow.out` and `.nextflow.log` in it. The exit
status is 0 only when every job passed.

Two differences from CI, both deliberate: the copy includes uncommitted and untracked files,
because those are what you are testing (so a file you forgot to `git add` passes here and
fails in CI: check `git status` before pushing), and Java is whatever `JAVA_HOME` points to.

Measured: all 184 jobs, 0 failed, 8.9 minutes at 6 jobs at a time on an otherwise idle
machine; 16.4 minutes (the suite then had 181 jobs) while two real workflows were running
beside it. One version alone takes about a third of that. A job that produces no result in
15 minutes is counted as failed.

**Before committing a tier 1 change or higher, run the whole suite, all three versions.**
The versions do differ (which handlers fire on a startup error, for one), so a pass on one
is not evidence for the others.

### When a stub job fails for outside reasons

Re-run the job before debugging it if you see one of these:

- `Error during download of plugin nf-amazon` (or `nf-schema`): a plugin download failed.
- `Can't stage file https://github.com/mriffle/nf-skyline-dia-ms/raw/main/resources/template.sky.zip`:
  the default Skyline template is fetched from GitHub at run time, in stub runs too. GitHub
  returned 504 for it for about 15 minutes on 2026-11-27 (audit item R19).

A negative job that prints a different error from the one it expects is not on this list, and
re-running it proves nothing. That was a defect in the workflow once (audit item R20, fixed
on 2026-11-28): a check inside a channel fired when a run was aborted at startup, and its
message could replace the real one. It passed on an idle 12-CPU machine and failed on the
4-CPU CI runners. To see such a race locally, give the job four CPUs and competition for
them: run eight copies at once under `taskset -c 0-3`, each in its own copy of the tree, and
look in `.nextflow.log` as well as at the console, because Nextflow 25 and later print only
the first error they log. SPECIFICATION.md, "Checks inside channels", has the rule that
prevents it.

### Adding or changing a stub config

- A new branch, option or regression case gets a config in `test-resources/` **and** an entry
  in the matrix in `push-stub-run.yml`; the suite script picks it up from there. Negative
  cases go under `negative-stub-run` with the message they must print.
- A config that uploads to Panorama needs an expected manifest. Generate it, then read it:

  ```bash
  nextflow run . -stub-run -c test-resources/<config> -c test-resources/ci.config
  test-resources/check-upload-manifest.sh <config> --update
  git status --short test-resources/expected/ && git diff test-resources/expected/
  ```
  (a new manifest is untracked, so `git diff` alone shows nothing: open the file)
- A stub block is part of the test. If a process gains an output, its stub must create it;
  if a step renames a file, the stub must do the same renaming, or the suite stops testing
  the names (see `BLIB_BUILD_LIBRARY` and the two Skyline stubs that fail on a collision).

### Docs

```bash
python3 -m venv /tmp/docs-venv && /tmp/docs-venv/bin/pip install -q -r docs/requirements.txt
/tmp/docs-venv/bin/sphinx-build -q -b html docs/source /tmp/docs-html
```

It should print nothing. Measured: 15 seconds including the install.

### The config GUI

A change to a parameter, a default, or which processes run is a two-repository change. In
`nf-skyline-dia-ms-config-gui`: copy `nextflow_schema.json` across by hand (the
`update-schema` script fetches from GitHub `main`, so it does not see uncommitted work), then

```bash
npm run regen-schema && npm run typecheck && npm test
```

Its coverage test fails if a schema parameter is unaccounted for. The diagram logic in
`src/workflow/computeWorkflowGraph.ts` is mirrored by hand and nothing checks it. Measured:
`npm test`, 639 tests, 20 seconds. That repository's `CLAUDE.md` is the authority.

## 5. The quoting check

```bash
python3 test-resources/check-script-quoting.py
```

It takes a second, needs nothing installed, and is the only automated check that looks inside
`script:` blocks. Run it after touching any process. It checks two rules: a `path` input is
never written inside quotes (`"${fasta}"` is wrong, `${fasta}` or `"${fasta.name}"` is
right), and a name derived from an input is never written bare (`"${x.baseName}.ssl"`). A
line that is correct for a reason the script cannot see is exempted with a trailing
`# quoting-ok`. It says nothing about whether the command is otherwise right.

## 6. Real runs

Everything for real runs is in `test-resources/real-runs/`:

| File | Purpose |
|---|---|
| `test-data.sh` | builds and verifies the test cache |
| `machine.config` | resource limits and cache directories, read from the environment |
| `scenarios/*.config` | one file per scenario or modifier |
| `run-case.sh` | runs one case in a "lane" and files its results |
| `summarize-run.sh` | reduces a run to small text files (called by `run-case.sh`) |
| `compare-runs.sh` | compares two summaries |

### The test cache

Test data is never committed. It lives in one directory, `$NFDIA_TEST_HOME`, which must be
outside every git repository and outside `/tmp` (the script refuses otherwise):

```
$NFDIA_TEST_HOME/
  MANIFEST.sha256      checksum of every file under data/
  IMAGES.*.tsv         the container images pulled, with digests
  data/                inputs: fasta/ skyr/ metadata/ raw/ raw-batches/ lib/ mzml/ mzml-short/ bruker-synthetic/
  nf-cache/panorama/   the workflow's download cache (panorama_cache_directory)
  nf-cache/mzml/       the workflow's mzML cache (mzml_cache_directory)
  runs/<lane>/         launch directories: work/, .nextflow/  (disposable)
  out/<case>/          what each run produced, and its summary  (disposable)
  code/                worktrees of other commits, for comparisons
```

**Check the space first:**

```bash
test-resources/real-runs/test-data.sh check
```

It prints free space on the cache's file system and in Docker's image store, the CPU and
memory, the Java and Docker versions, and whether Docker can use a GPU. What is needed:

| For | Test cache | Docker images |
|---|---|---|
| The core set | 3.3 GB | 13.5 GB |
| Every scenario in this guide | 12.3 GB | 27.6 GB |
| Each lane, while in use | about 1 GB per cold run, growing with each resumed case | |

If there is room, build the cache as below and leave it in place: the next reader verifies it
with one command instead of downloading again. If there is not, see
[no room for a cache](#no-room-for-a-cache).

**Build it** (in this order; the later steps cut their inputs from what the first run made):

```bash
R=test-resources/real-runs
$R/test-data.sh fetch                 # FASTA, report templates, metadata tables.   3 s
$R/test-data.sh images core           # or `all`. Pulls and records digests.        see below
$R/run-case.sh a pdc-181 . pdc        # first real run: downloads and converts the raw files. 13 min
$R/test-data.sh local-raw             # copy the raw files to data/raw for the local scenarios
$R/test-data.sh keep-lib pdc-181      # keep that run's .blib as the library for other scenarios
$R/test-data.sh derived               # short mzML files, Carafe input, synthetic .d.zip.   11 s
$R/test-data.sh verify                # check everything against MANIFEST.sha256
```

`images all` took 12 minutes to pull the 10.3 GB that was missing here; the Cascadia image
alone is 9.3 GB, so use `images core` unless you need Cascadia or Carafe.

**Where each piece comes from:**

| Data | Source | Size | Check |
|---|---|---|---|
| Three Thermo raw files, human pancreas DIA (`data/raw`, `nf-cache/panorama`) | PDC study [PDC000504](https://pdc.cancer.gov/pdc/study/PDC000504) (CPTAC PDAC BioTExt proteome). There is no fixed URL: the workflow asks the PDC for signed links (`pdc.study_id = 'PDC000504'`, `pdc.n_raw_files = 3`) and checks each file against the MD5 the PDC reports. | 943 MB | MD5 below |
| mzML of those files (`nf-cache/mzml`) | made by the workflow's msconvert step (no demultiplexing, `simAsSpectra`) | 1.05 GB | not fixed |
| Human Swiss-Prot FASTA (`data/fasta/human_sp_full.fasta`) | `https://rest.uniprot.org/uniprotkb/stream?query=(organism_id:9606)+AND+(reviewed:true)&format=fasta` | 13.7 MB, 20,429 entries | changes with every UniProt release; for release 2026_04 (4 November 2026) the SHA-256 was `13852e174364bf1c705206c38eacae57210f5bca9955f05be6b4ff48f727d37b` |
| Reduced FASTA (`human_sp_q4.fasta`) | every fourth entry of the above (`awk '/^>/{n++} n%4==1'`) | 3.4 MB, 5,108 entries | follows the above; `d36308f8f893928bc1becc6adaadae11b6381e9bbd4a4395a85da408446fb5e5` for 2026_04 |
| `precursor_quality.skyr`, `replicate_quality.skyr` (`data/skyr`) | `https://raw.githubusercontent.com/ajmaurais/DIA_QC_report/8604660754c01d0b081c7798d828564ea9a5b8b4/resources/` (pinned to a commit; the workflow's own QC defaults point at the same files on `master`) | 1.1 kB, 0.3 kB | SHA-256 `6729768739e30276e71356021b59f576b31b831adac74de831ec17bad43c7de0` and `de0eb34ac14bff1ecef8021b9e0cd334bef6d99e4cb3061a63cd7c62302c2b43` |
| Replicate metadata and PDC batch table (`data/metadata`) | written by `test-data.sh fetch` | under 1 kB | |
| Library for EncyclopeDIA, no-search and `library-blib` (`data/lib/final_diann_lib.blib`) | the `.blib` published by the `pdc` (or `local`) DIA-NN run | 4.9 MB | differs per run |
| Two mzML files cut to four minutes (`data/mzml-short`) | cut from the cached mzML with msconvert, `--filter "scanTime [2400,2640]"` | 24 MB each | not fixed |
| Carafe input (`data/mzml/carafe_input.mzML`) | a copy of one cached mzML | 302 MB | |
| Synthetic Bruker archives (`data/bruker-synthetic`) | made by `test-data.sh derived`; no spectra in them | under 1 kB | |
| Narrow-window (GPF) and wide-window raw files, human CSF, Exploris 480 | Panorama Public, project "MacCoss - Stellar highly multiplex fluid assays" (ProteomeXchange PXD065471). Folders `…/%40files/RawFiles/Exploris_CSF_GPF_DIA/` (6 files) and `…/Exploris_CSF_DIA_MMCC/` (the 3 `_N01_` files). Full URLs are in `scenarios/gpf.config`; the workflow downloads them. | 2.30 GB + 1.52 GB | sizes below |
| Chromatogram library of that project (`Exp_CSF_GPF_A.elib`) | same project, `…/RawFiles/DBsearchFiles/`; downloaded by the workflow in `gpf-encyclopedia` | 33.8 MB | |
| Default Skyline template | `resources/template.sky.zip` in this repository, fetched by the workflow from GitHub `main` at run time | 9 kB | |

PDC files (`pdc.n_raw_files = 3` takes the first three of the study's 84; a study's file list
can change, in which case `test-data.sh local-raw` will say a file is missing):

| File | Bytes | MD5 (as reported by the PDC) |
|---|---|---|
| `CPTAC_PDA_BioTEXT_DIA_JHU_C3L-02956_NAT_curls.raw` | 336,027,089 | `611ec11db586f0b9a381eeab5af4aa7e` |
| `CPTAC_PDA_BioTEXT_DIA_JHU_C3N-02754_NAT_bulk.raw` | 263,778,603 | `b6aac52f523485793264b9587f7de8c6` |
| `CPTAC_PDA_BioTEXT_DIA_JHU_C3N-02996_Stroma_Tumor_curls.raw` | 343,206,489 | `b78dac8874eb091fd4183ecec6248545` |

Panorama Public files (sizes as the server lists them; MD5 computed after download on
2026-11-27, since Panorama publishes none):

| File | Bytes | MD5 |
|---|---|---|
| `Dora_05022024_neo_150uID_15cm_npCSF_30mGPF_A_400-500_13.raw` | 315,594,802 | `e3ff3c0bbdd4347a9f0d902f24cdf4f2` |
| `…30mGPF_A_500-600_14.raw` | 386,843,607 | `0534ae0c51d6dc354a0137d6090a1b0b` |
| `…30mGPF_A_600-700_15.raw` | 436,404,931 | `04ea05c6d957288fbedb9e8b2845ca31` |
| `…30mGPF_A_700-800_16.raw` | 428,178,313 | `f4a51f70c10f32d668fef2975f9797d7` |
| `…30mGPF_A_800-900_17.raw` | 391,237,131 | `9780d70ced72fa8faf9541512c70a0b1` |
| `…30mGPF_A_900-1000_18.raw` | 341,812,268 | `dbe5550435214b24b1397a8e1ae1ba2b` |
| `Dora_05022024_neo_150uID_15cm_npCSF_MMCC_N01_63.raw` | 529,309,648 | `c9c1d3dcab79256bc66768c5f0b5f4cb` |
| `…MMCC_N01_78.raw` | 504,704,903 | `76b343abe17405d458b020f245e8341b` |
| `…MMCC_N01_93.raw` | 487,359,918 | `312f69a1c5bbcf289a27f78156ef0bbf` |

Panorama answers an anonymous `HEAD` request with 401 although `GET` works, so a tool that
probes with `HEAD` will wrongly report these files as private.

`MANIFEST.sha256` in the cache has the SHA-256 of every file under `data/`, including the
ones whose content is not fixed, as they were when the cache was built. `test-data.sh verify`
checks `data/` against it and the raw files in `nf-cache/panorama` against the MD5 values
above (8 seconds). Run it before trusting a cache you did not build, and run
`test-data.sh manifest` after deliberately changing something in `data/`. `verify` exits
non-zero when anything fails to match or a file under `data/` is not in the manifest.

**Container images** stay in Docker's own store once pulled; `IMAGES.core.tsv` and
`IMAGES.all.tsv` record the digest of each as pulled. To tell whether a tag has moved since,
compare with `docker image inspect --format '{{index .RepoDigests 0}}' <image>`. The DIA-NN
2.3.0 image's tag states that pulling it accepts the DIA-NN license. As pulled on 2026-11-27
(`core` is the first six):

| Image | Size | Digest (`sha256:`) |
|---|---|---|
| `ubuntu:22.04` | 0.08 GB | `4f838adc7181d9039ac795a7d0aba05a9bd9ecd480d294483169c5def983b64d` |
| `quay.io/protio/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.26120-bb3c999-fixed` | 6.13 GB | `60faa36768c654c2019f1f4cb2809a47c30dc9bb7ef8c87fbca449d57b15ecee` |
| `quay.io/protio/diann:1.8.1` | 0.62 GB | `2fde53d98c7e961a05ef99a869a61e46cc8349bc90aeda1e0396a31edb41d706` |
| `quay.io/mauraisa/diann:I_agree_to_the_DiaNN_2.3.0_license` | 2.20 GB | `905cba1a3d29067756c381081d3ee90a8a3da657607ec8b445436cf036065cff` |
| `quay.io/mauraisa/pdc_client:2.3.3` | 0.17 GB | `9fd093308407656ee70cb4b8aca2086b6531cfa0cd61ee83065312c7cc5f71c8` |
| `quay.io/mauraisa/dia_qc_report:2.7.0` | 4.29 GB | `d5329a46b5cbefdc66b0fd2fd37803269deab90f9569b68bc4cff7aad6ac325a` |
| `quay.io/protio/encyclopedia:2.12.30-2` | 0.51 GB | `6376f6a4b86804e3372615876592da1e418c6db81c42caba8f46bdda8ac0541c` |
| `quay.io/protio/encyclopedia:3.0.0-MRIFFLE` | 0.51 GB | `bc081c7ba6707bf825fe1d522e1f3a7f833fb5e61b477840103ca99062804011` |
| `quay.io/protio/panorama-client:1.1.1` | 0.55 GB | `a6503c19577d038372da7159b014b5edd8737c20f1309693c0502405c5c41e0b` |
| `quay.io/protio/bibliospec-linux:3.0` | 0.09 GB | `a62bdb92701ff789bc32e08e4d9d5345c42b094b0740ae4ce51d7bb5a80f648e` |
| `quay.io/protio/carafe:2.0.0-3` | 2.94 GB | `7de8563b0fa43923233a0f22301f4350b938fe91c8b405a4a4225095655104fd` |
| `quay.io/protio/cascadia:0.0.8` | 9.27 GB | `5fd4010e0cdd57208cbc56a6dbe523c88585fedd7e2a86cdcd59065bacf911be` |
| `quay.io/protio/cascadia-utils:0.0.4` | 0.28 GB | `7b1dffe956d34cb15e295adfc3d064d16b9f152851fff3427b63c8fa881a8a5e` |

#### No room for a cache

With less than about 20 GB free, do not build a durable cache. Put `NFDIA_TEST_HOME` on
whatever file system has room for one session, run only the core set, and remove everything
afterwards:

```bash
export NFDIA_TEST_HOME=/some/disk/with/room/nf-skyline-dia-ms-test
# ... fetch, images core, run, compare ...
git worktree remove "$NFDIA_TEST_HOME/code/main"       # if you made one (section 7)
docker run --rm -v "${NFDIA_TEST_HOME:?}:/t" ubuntu:22.04 rm -rf /t/runs /t/out /t/nf-cache /t/data
docker image rm quay.io/protio/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.26120-bb3c999-fixed   # 6 GB, if it must go
```

Everything can be fetched again from the sources in the table. Skip Cascadia (a 9.3 GB image)
and the GPF scenarios (3.8 GB of raw files) unless your change is in those branches.

### How a real run is launched

```bash
test-resources/real-runs/run-case.sh <lane> <case> <code-dir> <scenario>... [-- nextflow args]

test-resources/real-runs/run-case.sh a local-181 . local
test-resources/real-runs/run-case.sh b local-230 . local diann-2.3.0 metadata minimize
```

- **Lane**: a launch directory, `$NFDIA_TEST_HOME/runs/<lane>`. Every case in a lane runs with
  `-resume`, so a case repeats only the steps that differ from the cases before it. A second
  case in a warm lane takes one to five minutes instead of thirteen. One case at a time per
  lane; the script refuses a lane that is in use. `NFDIA_NO_RESUME=1` runs without `-resume`.
- **Case**: a name. Results are moved to `$NFDIA_TEST_HOME/out/<case>/results`, and
  `out/<case>/` also gets `run-info.txt` (exit status, seconds, commit, configs, task counts),
  `tasks.txt` (one line per task: `COMPLETED`, `CACHED` or `FAILED`, its work directory, its
  name), `nextflow.out`, the execution trace, the script and logs of any failed task, and
  `summary/`. A case of the same name is replaced. Lane and case names may contain only
  letters, digits, `.`, `_` and `-`.
- **Code directory**: the workflow to run. `.` for your working tree, or a worktree of
  another commit.
- **Scenarios**: names of files in `scenarios/`. `machine.config` is always passed first.
  The last `-c` file wins, which is why machine settings go first and modifiers last.
- **Secrets**: the run uses `$NFDIA_TEST_HOME/secrets.json`, created on first use with
  Panorama's published public key as `PANORAMA_API_KEY`. Your real secrets are not read.
- **Nextflow version**: whatever `nextflow` resolves to; set `NXF_VER` to pin it. The
  measurements here are on 25.10.4. The `local` scenario was also run on 24.10.5 and 26.04.0
  and matched the 25.10.4 result exactly, so one version is enough for routine real runs.
  The console output differs between versions (26.04 prints `[PROCESS …]` lines), which is
  why the scripts read task status from the trace file and you should read `tasks.txt`.

`machine.config` caps each task at 4 CPUs and 10 GB and lets one workflow run 3 tasks at
once. Override with `NFDIA_TEST_CPUS`, `NFDIA_TEST_MEMORY` and `NFDIA_TEST_FORKS`. For how
many workflows to run at once, see [housekeeping](#10-housekeeping).

### The core set

Two runs, one per lane, started together. Between them they execute the PDC metadata step,
both DIA-NN images (which name their outputs differently), and every Skyline step:
add-library, import, merge, annotate, minimize and reports. On an empty cache they also
execute the PDC download and msconvert; once the cache is built those two are skipped, and
in a lane that has run the scenario before, the searches are cached too. Read `tasks.txt`
to see what a given run really executed, and see
[steps that a cache hides](#steps-that-a-cache-hides).

```bash
R=test-resources/real-runs
$R/run-case.sh a pdc-181 . pdc &
$R/run-case.sh b local-230-meta-min . local diann-2.3.0 metadata minimize &
wait
```

Against `main` that is four runs: these two from the baseline worktree first, then these two
from your tree in the same lanes (section 7).

| Case | Cold | What a good result looks like |
|---|---|---|
| `pdc` | 13 min (30 tasks) | `CPTAC_PDAC_BioTExt_Proteome_annotated.sky.zip`; 3 replicates; 1,345 proteins, 9,664 peptides, 10,585 precursors; 46 published files; precursor report 31,756 lines |
| `local + diann-2.3.0 + metadata + minimize` | 13 min (22 tasks) | `final_annotated_minimized.sky.zip`; 3 replicates; 1,318 proteins, 10,219 peptides, 11,201 precursors |

The times are for the two running side by side. The long steps are library prediction (5 to
7 minutes), the three DIA-NN searches (about 4 minutes each, in parallel) and the three
Skyline imports (about 1 minute each). With less else running, every one of these took
about half as long. The counts depend on the UniProt release behind the
FASTA; compare them with a baseline run on your own cache, not with this table.

### Other scenarios

Run these only when the [table of processes](#which-scenario-runs-which-process) sends you
here. "Warm" is the time in a lane that has already run `local` or `pdc`.

| Scenarios passed to `run-case.sh` | What it executes beyond the core set | Measured | A good result |
|---|---|---|---|
| `local` | The plain baseline: local raw files, DIA-NN 1.8.1, no metadata. | 7 min cold with the mzML cached; 53 s warm | `final.sky.zip`, 39 published files |
| `local diann-2.3.0 vendor-raw` | `use_vendor_raw`: no msconvert; DIA-NN and Skyline read the `.raw` files. | 5 min in a lane that had predicted the 2.3.0 library | `final.sky.zip`; the precursor report differs from the mzML run in about 10% of lines, which is expected |
| `pdc pdc-batches` | Batch mode from `pdc.batch_file`. | 67 s warm | `…_BatchA_annotated.sky.zip` with two replicates and `…_BatchB_annotated.sky.zip` with one |
| `local-batches` (`+ diann-2.3.0`) | Batch mode from a `quant_spectra_dir` map; `MSCONVERT_MULTI_BATCH`. | 59 s warm | `final_Plate1.sky.zip`, `final_Plate2.sky.zip` |
| `local encyclopedia` | EncyclopeDIA, wide-window only: library conversion, three searches, the combined `.elib`. | 2.5 min warm | `final.sky.zip` holding `wide-combined-results.elib`; 8,845 peptides |
| `local library-blib` | DIA-NN given a `.blib`: `ENCYCLOPEDIA_BLIB_TO_DLIB` and `ENCYCLOPEDIA_DLIB_TO_TSV`, then a full search. | 2.5 min warm | `final.sky.zip` |
| `local no-search` | `search_engine = null`: Skyline with a supplied library. | 67 s warm | `final.sky.zip`, 20 published files |
| `local msconvert-only` | The early exit. | 9 s with the mzML cached, 36 s without | three mzML files and `nextflow_run_details.txt`, nothing else |
| `local template` | `skyline.template_file` given as a local file (the repository's own default template), so nothing is fetched from GitHub. | 54 s warm | matches plain `local` exactly |
| `local skip-skyline` | `skyline.skip`: the run ends after the search. | 9 s warm | exit 0; `diann/` outputs and no `skyline/` directory. `compare-runs.sh` has nothing to compare here; look at `diann/` yourself. |
| `bruker-unzip` | `UNZIP_DIRECTORY` on two synthetic `.d.zip` archives. | 9 s | exit 0; `synthetic_1.d` and `synthetic_2.d` in `nf-cache/scratch-bruker` (delete it afterwards) |
| `local qc-report` | The QC report steps. | 2 min warm | exit 0; `qc_report/final_qc_report.qmd` and `qc_report_data.db3`. No HTML is published; that is audit item R1, not your change. |
| `local carafe` | Carafe on CPU: a small DIA-NN search of one file, Carafe training (13 min), then the normal search with the Carafe library. | 22 min | `final.sky.zip`; `carafe/carafe_spectral_library.tsv` |
| `cascadia cascadia-gpu` | Cascadia de novo search of two four-minute files, scan-number fix, `.blib`, FASTA. | 8 min with a GPU (3.7 min per file) | `final.sky.zip` holding `lib.blib`; a few dozen peptides (26 here) |
| `panorama-public` | The two Panorama Public steps on one MS file (316 MB), then stop. | 24 s with its mzML already cached | one mzML published; the `.raw` in `nf-cache/scratch-panorama-public` (delete it afterwards) |
| `gpf` | Real narrow-window data from Panorama Public: both public Panorama steps, msconvert with demultiplexing, the DIA-NN narrow-window (subset library) search, then the wide files. | 20 min cold, of which 1 min download (3.8 GB) and about 10 min conversion; 43 tasks | `final.sky.zip` with three `…MMCC_N01_…` replicates; `diann/subset_library.tsv`; 2,079 precursors |
| `gpf gpf-encyclopedia` | EncyclopeDIA with a real chromatogram library: six narrow searches, the library `.elib`, three wide searches. Also `PANORAMA_GET_FILE` for the library. | 6.5 min after `gpf` | `final.sky.zip` holding `wide-combined-results.elib`; 12,751 peptides |
| `panorama-auth` | The authenticated Panorama listing and download of one MS file (316 MB), using the public key. | 28 s with its mzML already cached | one mzML published; the `.raw` in `nf-cache/scratch-panorama-auth` (delete it afterwards) |

Notes on these:

- **Cascadia and GPUs.** Use the GPU whenever there is one: `nvidia-smi` must work, and so
  must `docker run --rm --gpus all ubuntu:22.04 nvidia-smi` (`test-data.sh check` runs both).
  Then add `cascadia-gpu`. A full-length file took about 44 minutes on an RTX 4090, which is
  why the scenario uses four-minute cuts. Without a GPU, leave `cascadia-gpu` off, but expect it to be
  impractical: one file cut to a single minute of gradient (807 spectra) took 37 minutes on
  4 CPUs, so the four-minute files would take hours. If a Cascadia change must be tested on a
  machine without a GPU, cut one-minute files (`--filter "scanTime [2400,2460]"`), say so in
  the report, and ask whether that is enough. Each search used 9.3 GB of memory, close to
  the 10 GB cap in `machine.config`; do not lower `NFDIA_TEST_MEMORY` for it.
- **GPF data volume.** `gpf` downloads all six narrow and three wide files (3.8 GB) and
  converts them to 5.5 GB of mzML. It has not been tried on a subset; a chromatogram library
  built from fewer than the six m/z ranges would not be a realistic one anyway.
- **DIA-NN versions.** `gpf` and `local carafe` were run with the default DIA-NN 1.8.1 and
  `local-batches` and `vendor-raw` with 2.3.0. The other combination of each is untested.

#### Steps that a cache hides

`MSCONVERT`, `MSCONVERT_MULTI_BATCH`, `UNZIP_DIRECTORY`, `GET_FILE` (PDC) and the two
Panorama MS-file downloads have a `storeDir`: when their output is already in
`nf-cache/`, they do not run at all, whatever changed in their script. To test a change to
one of them, give that run empty cache directories and delete them afterwards. When
comparing two code trees, give each run its own empty directory: a second run pointed at the
first one's "fresh" directory finds the files there and skips the step again.

```bash
$R/run-case.sh a msconvert-change . local -- \
    --mzml_cache_directory "$NFDIA_TEST_HOME/nf-cache/mzml-fresh" \
    --panorama_cache_directory "$NFDIA_TEST_HOME/nf-cache/panorama-fresh"
```

Measured: `local msconvert-only` with an empty mzML cache converted the three files in 36
seconds. The files msconvert writes belong to root, so remove such a directory with
`docker run --rm -v "$NFDIA_TEST_HOME/nf-cache:/c" ubuntu:22.04 rm -rf /c/mzml-fresh`.
(The mzML cache key already includes the image and the msconvert options, so changing
`msconvert.*` parameters or the ProteoWizard image converts again without any of this.)

### Judging a run

A run is good when all of these hold:

1. `run-info.txt` says `exit=0`, and `tasks.txt` lists the step you changed as `COMPLETED`,
   not `CACHED` and not absent (a step skipped by a `storeDir` cache is absent).
2. `summary/documents.txt` shows the document you expect, by name, with the expected
   replicates and non-zero protein, peptide and precursor counts. An empty document is a
   failure even though the run exits 0.
3. The published file list (`summary/published_files.txt`) has what the change should add or
   remove, and nothing else moved.
4. For a change that should not alter results: it [matches `main`](#7-comparing-a-change-against-main).
   For one that should: the difference is the one you intended, and you can say why.

When a run fails, `out/<case>/failed-task/` has the task's `.command.sh` (the rendered
script: read it, it is the thing under test) and its logs. Several tools exit 0 after
failing (audit item R16), so "Missing output file(s)" usually means the tool's own log has
the real error.

## 7. Comparing a change against main

Make a worktree of the baseline once, outside the repository:

```bash
git fetch origin
git worktree add --detach "$NFDIA_TEST_HOME/code/main" origin/main
# later: git -C "$NFDIA_TEST_HOME/code/main" checkout --detach origin/main   (to move it)
#        git worktree remove "$NFDIA_TEST_HOME/code/main"                    (to drop it)
```

The baseline must be the code *without* your change. Work here is committed straight to
`main`, so once a change is pushed `origin/main` is the change: name the commit before it
instead (`git worktree add --detach … <commit>`). `compare-runs.sh` prints both `commit=`
lines and says so when they are the same.

**Quick comparison (same lane).** Run the baseline, then the change, in one lane. The second
run resumes from the first, so only the steps your change invalidates, and the steps after
them, execute again.

```bash
R=test-resources/real-runs
$R/run-case.sh a base-local "$NFDIA_TEST_HOME/code/main" local
$R/run-case.sh a cand-local . local
$R/compare-runs.sh base-local cand-local
```

Measured in a lane that had run `pdc`: 53 seconds for each of the two runs.

Check `grep COMPLETED "$NFDIA_TEST_HOME/out/cand-local/tasks.txt"`: **if the step you
changed is not listed as `COMPLETED`, it was not tested.** The resume cache is keyed on the
text of the `script:` block and the inputs, so a change that is only in a `stub:` block, an
output declaration, `stageAs`, a helper function or `publishDir` is reported as `CACHED`.
Use the independent comparison for those.

**Independent comparison (two lanes).** Each code tree gets its own lane and runs everything.
The candidate's lane must be one that has never been used, or the run resumes from whatever
an earlier iteration left there: use a new lane name for every iteration (or
`NFDIA_NO_RESUME=1`), and delete old lanes.

```bash
$R/run-case.sh base-1 base-local "$NFDIA_TEST_HOME/code/main" local &
$R/run-case.sh cand-1 cand-local . local &
wait
$R/compare-runs.sh base-local cand-local
```

Measured: the independent `local` run took 7 minutes with the mzML files cached and matched
the baseline exactly, so DIA-NN 1.8.1 gives identical reports in two separate runs on the
same machine. If two runs of the *same* code ever fail to match, establish that first: run
the baseline twice before blaming the change.

`compare-runs.sh` prints `MATCH` (exit 0) when all of these are identical:

- the final documents: names, the files inside each `.sky.zip`, replicate names, the numbers
  of proteins, peptides and precursors, the *number* of annotations (not their values), the
  libraries, and the number of audit-log entries;
- the list of published files (names only);
- every Skyline report, with its rows sorted. This is the comparison that looks at values:
  the precursor report has one row per precursor per replicate, with its areas and times;
- the spectrum count of every published mzML file (`msconvert-only` runs).

Its other answers: `MISMATCH` (exit 1); `NOT COMPARABLE` (exit 2) when either run did not
exit 0 or was not summarized, so two runs that failed the same way never "match"; and
`NO CONTENT COMPARED` (exit 3) when the file lists agree but neither run produced a
document, a report or an mzML file. Only `MATCH` is evidence. Every scenario here that makes
a document also makes the two reports; if you write a scenario without `skyline.skyr_file`,
its comparison rests on counts alone.

It deliberately does not compare bytes of the `.sky.zip` or `file_checksums.tsv`. Two runs of
the same code differ there: replicate order in the document follows the order in which the
imports finish, and a minimized library gets a new random ID on every run. That is also why
the reports are sorted before they are compared.

A change that renames inputs or replicates will not match as it is; map the names back
before comparing, and say that you did.

## 8. Pitfalls

Resume and configuration:

- **The last `-c` file wins**, and a value set in two files is taken from the later one
  without a warning. A machine config passed last once silently replaced the DIA-NN image
  under test.
- **Map parameters merge across `-c` files** instead of being replaced. A `quant_spectra_dir`
  batch map in a later file adds batches to an earlier map. Write one complete config per
  batch layout (hence `local-batches` is stand-alone).
- **`DIANN_BUILD_LIB` uses `cache 'deep'`**: it hashes the FASTA's content, not its name. A
  renamed FASTA is reported as cached and the library keeps the old name (audit item R15).
- **To force a cached step to run**, move its work directory aside and run the case again.
  The directory is in the previous run's `tasks.txt`: a line
  `CACHED  1d/355f6f  dia_search:diann:BLIB_BUILD_LIBRARY` means
  `$NFDIA_TEST_HOME/runs/<lane>/work/1d/355f6f…`. The step and everything after it then run.
- **The Skyline imports run again on every resume.** Under symlink staging the merge step
  deletes the import tasks' `.skyd` files. Expected; half a minute to a minute per file.
- **`skyline.use_hardlinks = true` fails under Docker here**, in `SKYLINE_IMPORT_MS_FILE`,
  with `ln: failed to create hard link … Operation not permitted`: the cached mzML files
  belong to root and the host has `fs.protected_hardlinks = 1`. To imitate AWS Batch
  staging, earlier work used `process.stageInMode = 'copy'` instead.
- **Do not edit the helper scripts while one of them is running.** Bash reads a script as
  it executes it, and a long-running `test-data.sh` or `run-case.sh` will trip over the edit.

Failures that are not your bug: the three listed under
[stub tests](#when-a-stub-job-fails-for-outside-reasons) apply to real runs too. A real run
that dies at `SKYLINE_ADD_LIB` with `Can't stage file …template.sky.zip` after a successful
search is the GitHub fetch (R19); resume it.

Known defects you will see and should not chase: the Cascadia steps publish empty log files
(R12) and a copy of every input mzML (R13); the rendered QC report HTML is never published
(R1); a Skyline template that already contains results fails in the merge step (R14). The
full list is the addendum of `AUDIT-2026-04-14.md`.

## 9. Known gaps

What cannot be tested with this guide, and what each would take:

| Gap | Why | What would close it |
|---|---|---|
| Panorama upload and Skyline import (`UPLOAD_FILE`, `IMPORT_SKYLINE`) | They need an account that can write to a Panorama folder. The stub suite checks only the upload plan. | An API key and a scratch folder from the maintainer; then `panorama.upload = true` with `panorama.upload_url`, the key in a private secrets file given as `NFDIA_SECRETS_FILE`. Ask first. |
| Downloads of private Panorama files | Only public files were fetched, through both the public and the authenticated steps. | The same account. |
| `PANORAMA_GET_SKYR_FILE`, replicate metadata read from Panorama | No public `.skyr` or matching metadata table was looked for. | A `.skyr` and a metadata TSV in a public Panorama folder, addressed with the lower-case `panorama%20public` trick. |
| Real Bruker `.d` data in DIA-NN and Skyline | No real `.d.zip` was at hand; the synthetic one tests extraction only. | A small public diaPASEF `.d.zip` (several GB) and a DIA-NN image that reads it. |
| AWS Batch (`-profile aws`), including the Secrets Manager steps and S3 staging | No AWS account was used. Copy staging can be imitated locally (`process.stageInMode = 'copy'`), nothing else. | A Batch queue and bucket to test in. |
| SLURM and Apptainer or Singularity, including Cascadia's `--nv` path | No cluster was used. | A cluster account. |
| `skyline.use_hardlinks = true` | Refused under Docker here (`fs.protected_hardlinks = 1`, outputs owned by root). | A host where task outputs belong to the user, such as Apptainer. |
| `MSCONVERT` (the process of that name) and Carafe with a `.raw` input or `carafe.spectra_dir` | The Carafe scenario gives Carafe an mzML file, and every other path converts with `MSCONVERT_MULTI_BATCH`. | One `local carafe` run with `carafe.spectra_file` set to a raw file in `data/raw` (about 25 minutes). |
| Real runs on Nextflow 24.10 and 26.04 beyond the `local` scenario | `local` matched on all three versions; nothing else was run on the other two. | `NXF_VER=… run-case.sh …` for the scenario in question. |
| Scale | Three files per run. Run time, scratch use and the memory directives (several are capped by `resourceLimits` here) are untested at hundreds of files. | A real project run by the maintainer. |
| Full-length Cascadia files | 44 minutes each with a GPU. | Time. |
| Slack delivery, completion email | The stub jobs prove only that a Slack failure never fails a run. | A webhook in a test channel; an SMTP account. |
| PDC options: `pdc.gene_level_data`, `carafe.pdc_files`, `carafe.pdc_n_files`, `pdc.s3_download`, `pdc.metadata_tsv` (and with it `METADATA_TO_SKY_ANNOTATIONS`), a `.d.zip` study | Not run for this guide (the first is QC report code). Stub configs exist for most. | One `pdc` run each with the option set. |
| File names with shell metacharacters other than spaces | Unchecked by design (SPECIFICATION.md). | |
| The QC report's HTML and PDF; the batch report, table export and gene report steps | Known broken (R1, R4) or never run here, and the code is to be replaced. | The replacement. |
| Scientific correctness | Nothing here knows the right answer. Comparisons are against `main`, so they catch changes, not long-standing errors. | A dataset with known content, such as a mixed-species benchmark. |
| Hosts other than Linux x86-64 | Everything was run under WSL2. The images are amd64 only. | |

## 10. Housekeeping

**Disk.** Measured during the 31 real runs behind this guide:

| What | Size |
|---|---|
| A lane after one cold core run | 0.9 GB |
| Each further case in the same lane | 0.3 to 1 GB (one lane held 8.5 GB after 11 cases, the other 7.3 GB after 7) |
| `out/<case>/results` | 0.3 to 0.4 GB for a DIA-NN case; 1 GB for `msconvert-only` (it publishes the mzML files); 1.6 GB for Carafe |
| `out/<case>/summary` | about 5 MB |
| The cache itself (`data/` + `nf-cache/`) | 3.3 GB for the core set, 12.3 GB with the GPF data |
| Everything after all 31 runs, before cleaning up | 42 GB |
| The same after the clean-up commands below | 13 GB |

Lanes and results are what grow. An earlier piece of work did 90 runs without cleaning and
took a disk from 76% to 96% full.

Clean up when a piece of work is finished:

```bash
# Results of cases you have judged (the summaries stay and are small):
rm -rf "${NFDIA_TEST_HOME:?}"/out/*/results

# A lane. Tasks write some outputs as root, so plain rm fails; let a container do it:
docker run --rm -v "${NFDIA_TEST_HOME:?}/runs:/runs" ubuntu:22.04 rm -rf /runs/<lane>
```

`data/` and `nf-cache/` are the cache: leave them. Never run `docker system prune -a` to make
room without checking what else on the machine uses Docker.

**How many workflows at once.** Each workflow started with `machine.config` runs up to 3
tasks of up to 4 threads. Memory was not the limit with this data: by the trace, DIA-NN
stayed under 2 GB, EncyclopeDIA and Carafe near 4 GB and Cascadia at 9.3 GB, and Docker
enforces the 10 GB cap per task. (The trace under-reports the Wine tasks, msconvert and
Skyline, at about 20 MB, so their real use is not known; none was killed.) CPUs are. One workflow per 6 CPUs and
per 16 GB of RAM, whichever gives fewer, is a safe rule: two on the machine above, one on a
4 to 8 CPU laptop (where `NFDIA_TEST_FORKS=1` keeps it responsive). Cascadia with a GPU runs
one search at a time regardless. Do not run the stub suite alongside real runs if you want
either to finish quickly: each stub job uses about two CPUs, the suite took nearly twice as
long beside two real workflows, and the two core runs took 13 minutes each beside it where a
comparable run with a quiet machine took 7.

**Stray files.** Stub runs started by hand in the repository leave `work/`, `.nextflow/`,
`results/`, `reports/` and `.nf-cache/` behind. They are git-ignored; remove them anyway.
`git status` must be clean of test artifacts before a commit, and no test data is ever
committed.

## Keeping this guide true

When a process, parameter or branch is added: add its stub config to the CI matrix, add a
row to [the table of processes](#which-scenario-runs-which-process), and add a scenario file
if no existing one executes it. When you measure something that contradicts a number here,
change the number and the date at the top.
