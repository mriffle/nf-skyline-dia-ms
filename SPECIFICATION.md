# nf-skyline-dia-ms Specification

## Overview

`nf-skyline-dia-ms` is a Nextflow DSL2 workflow for DIA mass spectrometry analysis.
It is built around a common end state of:

- resolved MS inputs
- an optional DIA search step
- a Skyline document
- optional QC and report generation
- optional Panorama upload

The repository is not a single linear pipeline. It contains several execution modes:

- a full analysis path
- a `msconvert_only` early-exit path
- a PDC-specific input path
- multiple search-engine branches
- an optional Carafe library-generation branch

The code is best understood as a small top-level orchestrator (`main.nf`) over reusable
workflows, subworkflows, and process wrappers.

## Problem Scope

The workflow is designed for DIA proteomics runs that may start from:

- wide-window quantification data
- optional narrow-window / GPF data for chromatogram-library generation
- a FASTA
- a spectral library, or no spectral library for DIA-NN prediction
- optional replicate metadata
- local files, Panorama WebDAV locations, or PDC study data

The implementation standardizes:

- file discovery and download
- RAW to mzML conversion
- Bruker `.d.zip` extraction
- search-engine-specific library preparation
- Skyline import and document creation
- QC report generation
- result packaging and Panorama upload

## Repository Structure

- `main.nf`
  Top-level orchestration, parameter checks, branch selection, and final packaging.

- `workflows/`
  High-level stages:
  - `workflows/dia_search.nf`
  - `workflows/skyline.nf`
  - `workflows/carafe.nf`

- `subworkflows/`
  Reusable orchestration blocks for input resolution, search pipelines, Skyline import,
  reporting, Panorama upload, and provenance.

- `modules/`
  Individual process wrappers for DIA-NN, EncyclopeDIA, Skyline, msconvert, Panorama,
  PDC, Cascadia, Carafe, QC tooling, and file statistics.

- `conf/`
  Base resource labels and output-directory configuration.

- `lib/`
  Plain Groovy helper classes, loaded automatically by Nextflow. `EmailTemplate.groovy` builds
  the completion email and `SlackNotifier.groovy` sends the Slack start/end notifications.

- `docs/`
  Sphinx documentation sources and build helpers for Read the Docs. The user-facing project
  docs live here, primarily under `docs/source/`.

- `nextflow.config`
  Default parameters, profiles, plugins, reports, and manifest metadata.

- `nextflow_schema.json`
  Parameter schema used by `nf-schema`.

- `container_images.config`
  Container image mapping for all wrapped tools.

- `test-resources/` and `.github/workflows/push-stub-run.yml`
  Stub-run coverage for representative branches. `test-resources/real-runs/` holds the
  scenario configs and scripts for real (non-stub) test runs; see `TESTING.md`.

## Main Runtime Flow

### 1. Startup and parameter handling

`main.nf`:

- enables DSL2
- runs `validateParameters()` from `nf-schema`
- maps deprecated Skyline params to nested `params.skyline.*`
- normalizes `search_engine` for local checks
- rejects `panorama.import_skyline` unless Panorama upload is enabled and Skyline is not skipped
- rejects `msconvert.do_demultiplex` when `use_vendor_raw` is set. Demultiplexing overlapping
  (staggered) DIA windows is done by msconvert's `demultiplex` filter, but `use_vendor_raw`
  skips msconvert and hands the raw files to DIA-NN and Skyline, neither of which demultiplexes
  them. Without this guard the run completed normally and silently quantified
  non-demultiplexed spectra. Checked before the `msconvert_only` guard below, so a config
  setting all three flags reports the conflict that changes results.
- rejects `use_vendor_raw` when `msconvert_only` is set, since skipping msconvert leaves an
  `msconvert_only` run with nothing to convert
- checks `skyline.document_name` with `validate_document_name` (`modules/utils.nf`) whenever
  a document will be made (not `msconvert_only`, not `skyline.skip`). Spaces are allowed; the
  shapes that cannot produce a document are rejected and the name is never rewritten (see
  "Document and batch names in file names" under Skyline, QC, and Reporting). On PDC runs
  that take the study name from the config (`pdc.metadata_tsv`), that name gets the same
  check when it replaces the default document name. In multi-batch mode the batch names
  (`quant_spectra_dir` keys or `pdc.batch_file` values) are checked for the same forbidden
  characters.
- rejects `pdc.gene_level_data` when its file name contains whitespace and the gene report
  step will run (`reject_whitespace_in_file_name` in `modules/utils.nf`). It is the one input
  whose name cannot contain a space; see "Input File Names"
- registers the Slack notification handlers as the first statements of the workflow block,
  before `validateParameters()`, and sends the Slack "started" message as its last statement
  (see "Slack notifications" under Configuration Model)

Checks inside channels:

Most checks run while the workflow block is being executed, before any channel carries a
value, and stop the run with one error. A few can only be made once inputs have been listed
or downloaded, so they sit inside a channel operator: the validation barrier in
`get_ms_files` (section 3), the PDC metadata check in `get_pdc_files`, the library check of
the no-search branch and the DIA-NN file-count check. Each of them asks `run_is_aborted()`
(`modules/utils.nf`) first and says nothing when it returns true. A new check of this kind
must do the same. The function reads Nextflow's session object, which is not a documented
interface; if a Nextflow version hides it, the function warns (`Could not read the run's
state`) and the checks behave as if no run were ever aborted.

The reason: when Nextflow aborts a run it terminates every operator, and a collecting
operator (`toList`, `groupTuple`, `ifEmpty`) answers by emitting what it has gathered so far.
After an error raised while the workflow was still being built that is nothing at all, so a
check for missing input fires on a run that never listed anything. Its error is logged in a
race with the real one, and Nextflow 25 and later print only the first error logged, so a bad
config could be reported with the wrong message, for example "No spectra files matched" for
directories that do hold files (audit item R20). Nextflow 24 printed both.

Relevant files:

- `main.nf`
- `modules/utils.nf`
- `nextflow.config`
- `nextflow_schema.json`

### 2. Panorama authentication setup on AWS

If the active profile is exactly `aws` and the run needs authenticated Panorama access,
`main.nf` creates or updates an AWS Secrets Manager secret containing `PANORAMA_API_KEY`.

The current auth-detection logic checks these inputs:

- `panorama.upload`
- `fasta`
- `skyline.fasta`
- `spectral_library`
- `replicate_metadata`
- `skyline.template_file`
- `quant_spectra_dir`
- `chromatogram_library_spectra_dir`
- `carafe.spectra_file`
- `carafe.spectra_dir`
- nested `skyline.skyr_file`

Relevant files:

- `main.nf`
- `modules/aws.nf`

### 3. Wide-window MS input resolution

The main wide-window branch is handled either by `subworkflows/get_pdc_files.nf` or
`subworkflows/get_ms_files.nf`.

For non-PDC runs, `get_ms_files`:

- accepts a local path, list of paths, or a batch map for `quant_spectra_dir`
- derives a regex from either `*_glob` or `*_regex`
- lists local files matching the regex
- lists matching files from authenticated Panorama or Panorama Public
- randomly samples files per batch when `files_per_quant_batch` is set
- enforces that every expected batch produced at least one matched file, raising a
  user-facing error before any downstream stage so misconfigured globs/regexes do not
  surface as opaque join-mismatch errors deeper in the workflow. A local directory without
  a match is rejected while the workflow is built ("No spectra files matched the glob/regex
  in local directories"); a Panorama folder without one is only known after its listing, and
  is rejected by the validation barrier, a channel operator ("No spectra files matched the
  glob/regex:"). The barrier is silent when the run is already being aborted (section 1,
  "Checks inside channels")
- enforces that all matched files have one MS-file type
- enforces a caller-supplied `allowed_extensions` allow-list, so engine/format
  incompatibilities (e.g., Bruker `.d.zip` with EncyclopeDIA or Cascadia) fail fast
  with a clear error instead of an opaque tool-internal failure later. `main.nf`
  derives the allow-list from `params.search_engine`:
  - `'encyclopedia'`, `'cascadia'` → `['raw', 'mzML']`
  - `'diann'`, `null` (no-search), or `params.msconvert_only == true` → `['raw', 'mzML', 'd.zip']`
- resolves one of:
  - `.mzML`
  - `.raw`
  - `.d.zip`
- either:
  - leaves mzML unchanged
  - converts RAW to mzML with ProteoWizard
  - unzips `.d.zip` into a Bruker `.d` directory

It emits:

- `ms_file_ch`
  The downstream MS inputs actually used by search and Skyline.

- `converted_mzml_ch`
  Only mzMLs produced by msconvert.

- `file_json`
  JSON-like file-name metadata consumed by replicate-metadata validation.

Channel convention:

- `ms_file_ch` is typically `tuple(batch_name, path)`
- non-batch runs use `batch_name = null`

Important detail:

- batch mode is determined in `main.nf` from
  `params.quant_spectra_dir instanceof Map || params.pdc.batch_file != null`

Schema note:

- the helper workflow can handle more shapes than the schema explicitly documents
- the public interface for batching is either a `quant_spectra_dir` Map (non-PDC) or
  `pdc.batch_file` (PDC)

Relevant files:

- `subworkflows/get_ms_files.nf`
- `modules/msconvert.nf`
- `modules/panorama.nf`

### 4. Optional narrow-window / GPF input resolution

If `params.chromatogram_library_spectra_dir` is set, `main.nf` runs the same
`get_ms_files` helper for narrow-window data.

Those files are used only by search engines that support a chromatogram-library step.
`main.nf` also builds:

- `all_ms_file_ch`
  All resolved MS inputs for run-details generation.

- `all_mzml_ch`
  Only converted mzML outputs, used later for Panorama upload in the full workflow.

### 5. PDC input branch

If `params.pdc.study_id` is set, `main.nf` bypasses normal spectra discovery and uses
`subworkflows/get_pdc_files.nf`.

That path:

- fetches study metadata with `PDC_client` (without `--nFiles`, so the full study file
  list is visible Nextflow-side), unless `params.pdc.metadata_tsv` is supplied
- converts metadata to Skyline annotations
- accepts metadata in `.json` or `.tsv` form
- partitions the file list into a quant set (first `pdc.n_raw_files` entries, or all
  files when null) and an optional Carafe subset (named or randomly sampled — see
  Section 9), then downloads the union with `PDC_client file`
- supports `.raw` and `.d.zip` inputs
- converts RAW to mzML unless `use_vendor_raw` is enabled
- emits Skyline-ready annotations that override user-supplied replicate metadata
- emits separate `wide_ms_file_ch` (main quant) and `carafe_pdc_ms_file_ch` (Carafe-only
  files) channels by joining post-conversion file stems against the role lookup; only
  the quant subset participates in the main analysis manifest and Panorama upload

PDC batch mode:

- if `params.pdc.batch_file` is set, the workflow reads a TSV file with `file_name` and
  `batch` columns that assigns each downloaded PDC file to a named batch
- the batch file is validated: every downloaded file must appear in the batch file and
  every file in the batch file must be present in the downloaded files
- downloaded files are emitted as `[batch_name, file]` tuples instead of `[null, file]`
- `use_batch_mode` is set to `true`, activating the same downstream per-batch Skyline
  document creation used by the non-PDC `quant_spectra_dir` Map path
- batch names are extracted from the batch file in `main.nf` and passed to the Skyline
  workflow as `batch_name_list`
- if `pdc.batch_file` is not set, behavior is unchanged: `[null, file]` tuples,
  single Skyline document

Additional behavior:

- if `skyline.document_name` is still `'final'`, the final Skyline document name is replaced
  with the PDC study name
- a study name fetched from PDC is made file-name safe by `PDC_client studyName --normalize`,
  which turns every run of characters other than letters and `_` into a single `_` (so it
  never contains a space, but can begin or end with `_`). With `pdc.metadata_tsv` the name is
  `pdc.study_name`, or `pdc.study_id` when that is null, taken as it is from the config.

Constraints:

- when `pdc.study_id` is set and `msconvert_only` is `false`, `search_engine` must be `'diann'`.
  EncyclopeDIA, Cascadia, and no-search mode are rejected at startup with an informative error.
  `msconvert_only` runs are exempt because no search executes.

Relevant files:

- `subworkflows/get_pdc_files.nf`
- `modules/pdc.nf`

### 6. `msconvert_only` early-exit mode

If `params.msconvert_only` is true, `main.nf`:

- resolves MS inputs
- writes `nextflow_run_details.txt`
- optionally uploads the resolved MS outputs to Panorama
- returns before auxiliary-input resolution, search, Skyline, QC, and checksum packaging

Important accuracy note:

- the Panorama upload helper is named `panorama_upload_mzmls`
- in this branch, `main.nf` passes `all_ms_file_ch`, not `all_mzml_ch`
- that means the uploaded files are the resolved downstream MS inputs, which are usually
  mzMLs, but may be extracted Bruker `.d` directories if that mode was selected. They can no
  longer be vendor RAW files: `use_vendor_raw` with `msconvert_only` is rejected at startup
  (see § 1), because it would skip the only step this mode exists to run.

### 7. Auxiliary input resolution

`subworkflows/get_input_files.nf` resolves:

- `params.fasta`
- `params.skyline.fasta`
- `params.spectral_library`
- `params.skyline.template_file`
- `params.skyline.skyr_file`

Current behavior:

- local files are supported
- authenticated Panorama URLs are supported
- Panorama Public is not implemented for these auxiliary inputs
- if no Skyline template is provided, the default template is fetched from the GitHub raw URL
  in `params.default_skyline_template_file`

Important implementation quirks:

- `params.skyline.skyr_file` supports multiple files
- private Panorama `.skyr` downloads work only when auth setup was triggered earlier
- `get_input_files.nf` checks `params.fasta` instead of `params.skyline.fasta` when deciding
  whether `skyline.fasta` needs Panorama download; private Panorama `skyline.fasta` therefore
  depends on the value of `params.fasta`

Relevant files:

- `subworkflows/get_input_files.nf`
- `modules/panorama.nf`

### 8. Replicate metadata resolution

For non-PDC runs, `subworkflows/get_replicate_metadata.nf` validates replicate metadata.

Supported branches in the code:

- local metadata files
- authenticated Panorama metadata URLs
- Panorama Public metadata URLs
- an empty placeholder file when metadata is omitted

The validation step compares metadata against `file_json` from the MS-input resolver.

Relevant files:

- `subworkflows/get_replicate_metadata.nf`
- `modules/qc_report.nf`

### 9. Optional Carafe library generation

If any of `params.carafe.spectra_file`, `params.carafe.spectra_dir`,
`params.carafe.pdc_files`, or `params.carafe.pdc_n_files` is set, `workflows/carafe.nf`
generates a spectral library before the main search branch. The four input sources are
mutually exclusive; the PDC-driven options additionally require `params.pdc.study_id`.

Current Carafe behavior:

- `carafe.spectra_file` remains the backward-compatible single-file input
- `carafe.spectra_file` may be local or an authenticated Panorama URL
- `carafe.spectra_dir` may be local or Panorama-backed and is filtered through:
  - `carafe.spectra_glob`
  - `carafe.spectra_regex`
- `carafe.spectra_dir` may resolve one or more spectra files for a single Carafe run
- supported spectra-file types are `.mzML`, `.raw`, and Bruker `.d.zip`
- `.raw` files are converted to mzML via msconvert; `.d.zip` files are extracted to `.d`
  directories via `UNZIP_BRUKER_D` and bypass msconvert. The extracted `.d` directories are
  cached in `panorama_cache_directory` (via `storeDir`), so extraction is skipped on re-runs
- all resolved spectra inputs (mzML files and/or `.d` directories) are staged into the Carafe
  work directory and Carafe is invoked with `-ms "."`
- PDC-driven Carafe input (`carafe.pdc_files` or `carafe.pdc_n_files`) bypasses
  `get_carafe_ms_files` and consumes pre-resolved post-conversion files supplied by
  `get_pdc_files`:
  - `carafe.pdc_files` is an explicit list of PDC file names; entries already in the
    main quant download set (within `pdc.n_raw_files`) are reused, and entries outside
    that set are downloaded additionally for Carafe but do not enter the main analysis
  - `carafe.pdc_n_files` is a random sample size drawn from the main quant set, seeded
    by `params.random_file_seed`; the sample is always a subset of the main quant set
    so no extra downloads occur
  - validation: `carafe.pdc_n_files <= pdc.n_raw_files` (when both set), all
    `carafe.pdc_files` names exist in the study, and `pdc.n_raw_files <= total study
    file count`
- local alternative inputs may be requested through:
  - `carafe.carafe_fasta`
  - `carafe.diann_fasta`
  - `carafe.peptide_results_file`
- if `carafe.peptide_results_file` is absent, a small DIA-NN build-lib + search step creates
  the peptide-results input
- the output library format is chosen from `params.search_engine`
  - `diann` if the search engine is DIA-NN
  - `diann` by default when `search_engine == null`
  - Encyclopedia-style output for other search engines

Main-workflow behavior:

- if both Carafe and `params.spectral_library` are set, Carafe overrides the user library

Important implementation quirks:

- the EncyclopeDIA subworkflow still validates `params.spectral_library` directly, so a
  Carafe-generated library does not fully replace `params.spectral_library` for that branch

Relevant files:

- `workflows/carafe.nf`
- `subworkflows/run_carafe.nf`
- `subworkflows/get_input_file.nf`
- `modules/carafe.nf`
- `modules/diann.nf`
- `modules/msconvert.nf`

### 10. DIA search dispatch

`workflows/dia_search.nf` routes execution to one of four branches:

- no-search
- EncyclopeDIA
- DIA-NN
- Cascadia

The shared output contract is:

- search-engine version text
- all search files intended for downstream upload
- search-file statistics text
- final spectral library for Skyline
- FASTA to use downstream

## Search Engine Branches

### No-search branch

Triggered when `params.search_engine == null`.

Behavior:

- requires Skyline not to be skipped
- requires a non-empty spectral-library channel
- skips search execution
- passes the provided library directly to Skyline
- emits empty search-version, search-files, and search-file-stats channels

### EncyclopeDIA branch

Implemented in:

- `subworkflows/encyclopedia/main.nf`
- `subworkflows/encyclopedia/encyclopedia_search.nf`
- `modules/encyclopedia.nf`

Behavior:

- requires `params.fasta`
- requires `params.spectral_library`
- converts `.blib` to `.dlib` when needed
- if narrow-window data exists, searches narrow mzMLs and builds a chromatogram `.elib`
- runs wide-window quantification using the chosen library
- emits:
  - the final combined `.elib`
  - peptide quant output
  - protein quant output

Constraint:

- batch mode is not supported

Important nuance:

- the branch validates `params.spectral_library`, not just the incoming library channel

### DIA-NN branch

Implemented in:

- `subworkflows/diann/main.nf`
- `subworkflows/diann/diann_search.nf`
- `modules/diann.nf`
- `modules/encyclopedia.nf` for library conversion

Behavior:

- requires `params.fasta`
- uses a supplied library when present
- converts `.blib` or `.dlib` libraries into DIA-NN TSV when required
- otherwise predicts a library from FASTA
- if narrow-window data exists, performs a subset/profiling search first
- runs wide-window quantification through `DIANN_QUANT`
- performs a second `DIANN_MBR` aggregation / reanalysis step
- builds a Skyline `.blib` unless Skyline is skipped

Output naming by DIA-NN version:

- DIA-NN 1.8.x (the default image) writes a TSV precursor report and a `.tsv.speclib`; later
  versions (confirmed with 1.9.2 and 2.3.0) write a parquet report and a
  `.parquet.skyline.speclib`. `DIANN_MBR` (and `DIANN_SEARCH`, `CARAFE_DIANN_SEARCH`) detect
  which set DIA-NN produced and rename it to `<name>.tsv` + `<name>.tsv.speclib` or
  `<name>.parquet` + `<name>.parquet.skyline.speclib`, where `<name>` is `quant` (or
  `subset_library` for the narrow-window search).
- every consumer of those outputs must accept both sets. `BLIB_BUILD_LIBRARY` does so in
  `blib_build_input_script()`: BlibBuild is given only the speclib and derives the report's file
  name from it, so the staged files are renamed to a pair BlibBuild matches explicitly
  (`<name>-lib.parquet.skyline.speclib` + `<name>.parquet`, or `<name>-lib.tsv.speclib` +
  `<name>-report.tsv`). The `.blib` has the same name either way.
- under `-stub-run` the DIA-NN stubs pick the set from the version in the `images.diann` tag
  (`diann_stub_output_names()`): a version below 1.9 gives the 1.8.x names, anything else the
  newer names. Stub configs that keep the default image therefore cover the 1.8.x names, and
  `test-diann-v2-naming.config` covers the newer names. The `BLIB_BUILD_LIBRARY` stub runs the
  same renaming as the real script, so a consumer that handles only one set fails in CI.

Capabilities:

- supports batch mode
- supports vendor RAW input through DIA-NN stage-in settings

### Cascadia branch

Implemented in:

- `subworkflows/cascadia/main.nf`
- `modules/cascadia.nf`

Behavior:

- runs Cascadia on the resolved wide-window MS inputs
- fixes scan numbers in per-file SSL results
- combines SSL files
- builds a `.blib`
- creates a FASTA from identified sequences for downstream Skyline import

Constraints:

- batch mode is not supported
- user-supplied spectral libraries are ignored with a warning

Practical note:

- the workflow normally feeds Cascadia converted mzMLs unless `use_vendor_raw` changes the
  upstream resolver behavior

## Skyline, QC, and Reporting

Implemented in:

- `workflows/skyline.nf`
- `subworkflows/skyline_import.nf`
- `subworkflows/skyline_run_reports.nf`
- `subworkflows/generate_qc_report.nf`
- `modules/skyline.nf`
- `modules/qc_report.nf`

If `params.skyline.skip` is false, the Skyline stage:

- adds the final spectral library to a Skyline template
- imports MS data one file at a time
- groups imported files by batch
- merges them into one document per batch or one document overall
- annotates the document when replicate metadata or PDC annotations are available
- optionally runs a minimize step
- publishes the final document to `skyline/final_documents` from whichever of
  `SKYLINE_MERGE_RESULTS`, `SKYLINE_ANNOTATE_DOCUMENT`, or `SKYLINE_MINIMIZE_DOCUMENT` is the
  terminal step for that run. Only the terminal step shares the document as a `.sky.zip` and
  writes its MD5 hash; the non-terminal steps publish only their logs to
  `skyline/import-spectra`, so no intermediate `.sky.zip` exists
- optionally runs user-provided `.skyr` reports
- optionally generates QC outputs from Skyline report exports

Document hand-off between Skyline steps:

- a non-terminal step passes the document to the next one as a directory (`skyline-document/`
  from merge, `annotated-document/` from annotate) holding the `.sky`, its `.skyd`, its `.skyl`
  audit log, and the spectral library, rather than zipping it and unzipping it again
- Skyline looks for the per-file `.skyd` caches only in the directory of the document it opens,
  so `SKYLINE_MERGE_RESULTS` moves the staged caches next to the document before it runs
- the merge step prunes the directory before handing it on: Skyline leaves the template
  document and a second full-size copy of the chromatogram cache there
- a step never writes into the directory it receives; annotate saves into a new directory and
  copies the library and any other sidecar files next to the new document
- `SKYLINE_ADD_LIB` always names its document `results.sky.zip`. `SKYLINE_MERGE_RESULTS` stages
  it under `add-lib-document/` rather than in the task directory, so the file names derived
  from `skyline.document_name` can never be the path of the staged document. Staged directly,
  a document named `results` made the merge step write `results.sky.zip` over its own input:
  Skyline replaces the file and, under symlink staging, deletes the `SKYLINE_ADD_LIB` output it
  links to. With that name the template and the merged document are still the same file
  (`results.sky`), which Skyline simply saves in place
- `SKYLINE_ADD_LIB` stages the template under `template-document/` for the same reason. A
  template file that is itself named `results.sky.zip` (every run publishes one to
  `skyline/add-lib`, so reusing it as a template is natural) used to be replaced by this
  step's output, and under symlink staging Skyline deleted the file it linked to: the user's
  own template. The run still reported success
- the stub blocks of `SKYLINE_ADD_LIB` and `SKYLINE_MERGE_RESULTS` fail if the ZIP they are
  about to write is already present as a staged input. `touch` would pass through the staged
  link, so without that check a stub run could not see either collision
- stub runs do not execute Skyline, so a change to these steps needs a real run to verify

Batch naming:

- the final document basename is `skyline.document_name`
- in batch mode, batch names are appended as `document_batch`
- the annotate and minimize steps append `_annotated` and `_minimized`; a trailing underscore
  on the incoming name is replaced by the suffix, not doubled (`mydoc_` becomes
  `mydoc_annotated`)
- `get_final_skyline_doc_name` in `subworkflows/skyline_import.nf` builds the name of a
  batch's final document from the document name, the batch name and the steps that run, using
  the same helpers that name the process outputs. `workflows/skyline.nf` joins the final
  documents to their batches on that predicted file name. Nothing is recovered by parsing an
  output file name: a suffix that is part of the user's name cannot be told from one a step
  added
- because the suffix replaces a trailing underscore, batches `A` and `A_` would share a final
  document name when annotate or minimize runs; `check_final_skyline_doc_names` rejects that
  at startup
- a new Skyline step that renames the document must be added to `get_final_skyline_doc_name`;
  if it is not, the join fails on every run, including every stub config

Document and batch names in file names:

- the document name is also the start of the DIA-NN library name
  (`<document_name>_diann_lib.blib`, `get_blib_name()` in `modules/diann.nf`) and, outside
  batch mode, the DIA-QC project name, which `dia_qc qc_qmd` puts in front of the QC report
  file name (`<document_name>_qc_report.qmd`). In batch mode the batch name is the project
  name and the prefix of every exported Skyline report.
- both names may contain spaces, and those spaces reach file names unchanged. Every script
  that uses one of these names, or a file named after one, therefore has to quote it:
  - a `val` holding a name is always written inside quotes (`--project "${batch}"`)
  - a `path` variable is written bare (`unzip ${skyline_zipfile}`): Nextflow
    backslash-escapes it for exactly that use. It must not be put inside quotes, where the
    backslash survives (`"my\ doc.blib"`) and the program is given a file name that does not
    exist. To get a quoted file name use `"${file.name}"`. The same rules make input file names
    with spaces work; they are set out in full under "Input File Names".
  - anything that parses a file name out of text must not split on whitespace (see
    `parse_md5sum_line` in `subworkflows/combine_file_hashes.nf`)
- `validate_document_name` rejects, at startup, only the names that cannot work: path
  separators, the characters Windows does not allow in file names (`: * ? " < > |`, which
  Skyline cannot save), the characters that end or expand a quoted shell string
  (`'`, backtick, `$`), control characters, and a leading space or `-`. Batch names have their
  own check, `validate_batch_names`, which is narrower (empty, `/`, `\`, control characters)
  and applies to every run. When a document will be made, `validate_batch_names_for_documents`
  also rejects the same forbidden characters in a batch name, since the batch name is part of
  the document name. It does not reject a leading `-`, which is not at the start of the
  document name and can work when no QC or Skyline report is made.
- stub runs execute neither Skyline nor `dia_qc`, so they show that the channel joins, the
  checksum table and the upload manifest cope with a space, not that the tools do

QC behavior:

- `generate_dia_qc_report` exports two Skyline reports:
  - replicate quality
  - precursor quality
- those reports are merged into a DIA-QC SQLite database
- the merged DB is then passed through filter / impute / normalize logic
- by default, `qc_report.normalization_method` is `'median'`, so normalization runs unless
  that param is explicitly set to `null`
- optional outputs include:
  - rendered QC reports
  - the generated QMD
  - the QC database
  - exported QC tables

Batch-report behavior:

- batch reports are generated when `batch_report.skip` is false
- the underlying processes publish HTML/PDF/Rmd/TSV outputs directly
- those batch-report outputs are not emitted from `workflows/skyline.nf`
- therefore they are not included in the downstream checksum manifest or Panorama upload

PDC gene-report behavior:

- if `params.pdc.gene_level_data` is set and QC generation ran, gene-level reports are exported
- those gene reports are emitted and do participate in checksum packaging

## Provenance, Hashing, and Output Packaging

### Run details

`subworkflows/save_run_details.nf` writes `nextflow_run_details.txt` containing:

- workflow start time
- Nextflow version
- repository / revision / commit metadata
- session ID
- command line
- input-file names gathered by `main.nf`
- parsed tool versions, from every version channel: search engine, Skyline / msconvert,
  DIA-QC, Carafe, and PDC_client
- configured container image names

`Channel.concat` drops every argument after a null one, so a version variable that is declared
but never assigned silently removes all the versions after it. Keep every entry in the
`version_files` concat a real channel (`Channel.empty()` when the step did not run).

### Combined file hashes

`subworkflows/combine_file_hashes.nf` builds a combined checksum-and-size table by mixing:

- precomputed search-file stats from the search subworkflow
- calculated md5 values for FASTA files, libraries, Skyline outputs, QC outputs, gene reports,
  report files, and run-details files

Important accuracy note:

- this manifest is not a complete list of every published artifact in the repository
- coverage depends on what each search branch includes in its `search_file_stats`
- the final Skyline document is always covered, and its recorded path is
  `skyline/final_documents` for every branch
- PDC runs contribute the contents of `<result_dir>/pdc` (study metadata, derived Skyline
  annotations, and the PDC_client version) via `get_pdc_files.out.pdc_files`
- currently omitted or inconsistently covered artifacts include:
  - batch-report outputs
  - some search outputs such as final EncyclopeDIA combined outputs and Cascadia `.blib`

### Panorama upload

`subworkflows/panorama_upload.nf` uploads selected outputs under:

- `nextflow/<timestamp>/<workflow.sessionId>/...`

For full analysis runs, Panorama upload includes:

- at the run root: run details, the combined file-hash table, and one config file captured by
  `workflow.configFiles[1]`
- `input-files/`: the set assembled by `main.nf` under `if(params.panorama.upload)` -- the
  user-supplied FASTAs (`params.fasta` and `params.skyline.fasta`, deduplicated), the user or
  Carafe spectral library, `.skyr` files, the Skyline template, the replicate metadata, and any
  user-authored PDC inputs (`pdc.batch_file`, `pdc.gene_level_data`, `pdc.metadata_tsv`). On PDC
  runs where the metadata was fetched from the API rather than supplied, the study's flattened
  metadata JSON is included as well: a study's file set can change over time, and that file is
  the only record of which files this run actually downloaded
- `results/msconvert[/<batch>]/`: converted mzML files from `all_mzml_ch`
- `results/<search_engine>/`: search files
- `results/skyline/`: final Skyline documents
- `results/skyline_reports/`: Skyline report outputs
- `results/gene_reports/`: PDC gene-level tables, when `pdc.gene_level_data` is set

`subworkflows/panorama_upload.nf` also writes `panorama_uploads.tsv` (file name, destination URL)
to the local `panorama/` results directory, from the same channel that feeds `UPLOAD_FILE`. It is
the record of what was uploaded, and it is what the stub tests assert against: the upload command
itself never runs under `-stub-run`, so the manifest is the only observable form of the upload
plan. `test-resources/check-upload-manifest.sh` compares it against the expected manifests in
`test-resources/expected/`, with the per-run `nextflow/<timestamp>/<sessionId>` prefix normalized.
Note that no stub test can cover the Panorama client itself -- argument handling, auth, or
LabKey-side directory behavior.

The `input-files/` set is intended to be everything needed to reproduce the run. Two details
govern it:

- the replicate metadata channel carries an empty placeholder file when no metadata was
  supplied and the run is not a PDC study, so it is uploaded only when
  `params.replicate_metadata` or `params.pdc.study_id` is set. On PDC runs the uploaded file is
  the annotations CSV generated from the study metadata, not a user-supplied file
- the search FASTA is deliberately not the source for `input-files/`. On Cascadia runs it is a
  search product and is already uploaded under `results/cascadia/`; the user-supplied FASTAs are
  taken from `get_input_files` instead

For `msconvert_only` runs, the upload path is smaller and only includes the resolved MS outputs,
run details, and the selected config file.

If `params.panorama.import_skyline` is true, Panorama import runs only after file uploads finish.

Important accuracy note:

- QC reports and batch reports are not part of Panorama upload in the current implementation
- `IMPORT_SKYLINE` writes `panorama-import-skyline.stdout` / `.stderr` under fixed names, so in
  batch mode the per-document logs overwrite each other in the local `panorama/` directory

## Configuration Model

Primary config files:

- `nextflow.config`
- `conf/base.config`
- `conf/output_directories.config`
- `container_images.config`

Profiles defined in `nextflow.config`:

- `standard`
- `aws`
- `slurm`

Global reporting configured in `nextflow.config`:

- execution timeline
- execution report
- execution trace

Key parameter families:

- input data:
  - `quant_spectra_dir`
  - `chromatogram_library_spectra_dir`
  - `fasta`
  - `spectral_library`
- search:
  - `search_engine`
  - `diann.*`
  - `encyclopedia.*`
  - `cascadia.*`
- Skyline:
  - `skyline.*`
- QC and batch reporting:
  - `qc_report.*`
  - `batch_report.*`
- Panorama:
  - `panorama.*`
- notifications:
  - `email`
  - `slack.*`
- PDC:
  - `pdc.*`
- Carafe:
  - `carafe.*`

Other framework behavior:

- `search_engine` defaults to `encyclopedia`
- optional completion email is sent from `workflow.onComplete` when `params.email` is set and
  mail settings are configured

### Slack notifications

When `slack.enabled` is `true`, the workflow posts one message when a run starts and one when
it ends (success or failure) to a Slack incoming webhook. The implementation is
`lib/SlackNotifier.groovy`, called through `slack_notify()` in `main.nf`.

Rules that must be preserved:

- **A Slack problem never fails or stalls a run.** `slack_notify()` and `SlackNotifier` catch
  everything, the POST has 5 second connect and read timeouts inside a 15 second hard limit,
  there are no retries, and every problem becomes one `log.warn`.
- **The webhook URL is the Nextflow secret `SLACK_WEBHOOK_URL`, never a parameter.** The
  config file passed with `-c` is uploaded to Panorama as-is, so a credential in `params`
  would leak. Warnings never include the URL or an exception message (exception messages can
  contain the URL); they carry only an exception class name or an HTTP status.
- **The handlers are registered before anything that can fail.** An error raised before a
  handler is registered notifies no one, so registration precedes `validateParameters()`.
- **Both `onComplete` and `onError` are registered.** Nextflow versions before 25 fire only
  `onError` for an error during workflow construction; 25 and later fire both.
  `SlackNotifier` sends the end message once. `onError` sends it only if the start point was
  never reached, because with the default `finish` error strategy `onError` fires at the first
  failed task while the run may continue for a long time; the "failed" message therefore
  comes from `onComplete`, the real end.
- **"Started" is sent from the last statement of the workflow block**, after every
  construction-time check in `main.nf` and the subworkflows, so a bad config yields a single
  "failed" message. The `msconvert_only` branch returns early and makes the same call just
  before its `return`. Any new early exit from the workflow block must do the same.

Not covered: if the Nextflow process itself is killed outright (`kill -9`, node loss, a
scheduler hard-kill), no handler runs and no message is sent.

## Input Source Support Matrix

Current implementation support is uneven by input type:

- `quant_spectra_dir`:
  local, authenticated Panorama, Panorama Public

- `chromatogram_library_spectra_dir`:
  local, authenticated Panorama, Panorama Public

- `replicate_metadata`:
  local, authenticated Panorama, Panorama Public
  note: Panorama Public validation is currently miswired as described above

- `fasta`, `spectral_library`, `skyline.template_file`:
  local and authenticated Panorama only

- `skyline.skyr_file`:
  local and authenticated Panorama only

- `carafe.spectra_file`:
  local and authenticated Panorama only
  accepts `.mzML`, `.raw`, and Bruker `.d.zip`

- `carafe.spectra_dir`:
  local, authenticated Panorama, Panorama Public
  selected with `carafe.spectra_glob` or `carafe.spectra_regex`
  accepts `.mzML`, `.raw`, and Bruker `.d.zip` (single extension per run)

- `pdc.*`:
  separate PDC client branch

- `pdc.batch_file`:
  local only; TSV with `file_name` and `batch` columns that assigns PDC files to batches

- `carafe.pdc_files`, `carafe.pdc_n_files`:
  PDC-only; subset of the PDC quant download is reused as Carafe input
  (no separate file resolution; mutually exclusive with the four other Carafe input modes)

## Input File Names

Every user-supplied input file may have spaces in its name, and so may the directories it is
in: the MS files (`.raw`, `.mzML`, `.d.zip`, from local directories, Panorama or the PDC), the
FASTA files, the spectral library, the Skyline template, `.skyr` files, the replicate metadata,
`pdc.metadata_tsv`, `pdc.batch_file` and the Carafe inputs. Names are never rewritten: an MS
file `Sample 01.raw` becomes `Sample 01.mzML` and the replicate `Sample 01`.

The one exception is `pdc.gene_level_data`. It is read only by `EXPORT_GENE_REPORTS`, part of
the QC reporting code, whose script was left as it is; `main.nf` rejects a name with
whitespace at startup when that step will run.

What makes this work, and what a change to a process script has to keep:

- Nextflow backslash-escapes a `path` variable written directly in a `script:` or `stub:`
  block (`${fasta}` renders as `my\ file.fasta`), so that it can be used bare. Nothing else is
  escaped: `${fasta.name}`, `${fasta.baseName}`, `fasta.toString()`, the elements of
  `files.join(' ')`, and any string built in a helper function all render with the space as
  it is. This is the same on Nextflow 24.10, 25.10 and 26.04.
- So a `path` input is written bare (`-f ${fasta}`) or by name inside quotes
  (`--import-fasta="${fasta.name}"`), never as `"${fasta}"`: inside quotes the backslash
  survives and the tool is asked for a file that does not exist. The same goes for a line that
  is echoed into a Skyline batch file.
- A name derived from an input is always quoted (`--out "${ms_file.baseName}"`,
  `touch "${metadata.baseName}.annotations.csv"`), in stub blocks too. The one exception is
  `--out-lib ${fasta_file.baseName}.speclib` in `DIANN_BUILD_LIB`, which works unquoted
  because DIA-NN joins its arguments back together and is left alone for the reason given
  under "Changing a process script" below.
- Helper functions that build shell text from file names quote each name themselves
  (`join_ms_files` in `modules/diann.nf`, `shell_quote` in `modules/msconvert.nf`).
- Shell code that takes a file name apart must quote the result. `ENCYCLOPEDIA_CREATE_ELIB`
  renames `<name>.mzML.*` to `<name>.dia.*` with `"${0/.mzML/.dia}"`; note that inside double
  quotes a backslash in the replacement is kept, so it is written without one.

`test-resources/check-script-quoting.py` checks the second and third rules for every process
in `modules/` and runs in CI. It is needed because stub blocks only `touch` files: a script
that passes a tool a file name that does not exist still passes every stub config.

Tools that needed nothing: msconvert, DIA-NN (1.8.1 and 2.3.0), EncyclopeDIA's per-file
search and library conversion, BlibBuild, Carafe, Cascadia, `dia_qc validate` and
`metadata_convert`, `PDC_client` and SkylineCmd all accept names with spaces when they are
given them correctly.

Changing a process script:

- Nextflow's resume cache is keyed on the text of the `script:` block, not on what it renders
  to. Any edit inside that block, a comment included, makes `-resume` repeat the step and
  everything after it for a run started before the edit. Edits to output declarations, to
  `stub:` blocks and to helper functions do not.
- This is why two scripts that would otherwise have been tidied were left exactly as they
  were. `DIANN_BUILD_LIB` feeds the whole DIA-NN search, and `PANORAMA_GET_FILE` /
  `PANORAMA_GET_SKYR_FILE` download the FASTA, library and template: re-running either moves
  its output to a new work directory, and `DIANN_QUANT` and `ENCYCLOPEDIA_SEARCH_FILE` would
  then run again for every file. Comments explaining them are placed above `script:`.
- A fix that does have to change a script is still worth making; just say in the commit
  message which steps a resumed run will repeat.

Panorama downloads:

- the Panorama client names a downloaded file after the decoded last segment of the URL, so
  `.../my%20library.blib` is saved as `my library.blib`. The download processes declare that
  name (`panorama_file_name` in `modules/panorama.nf`) as their output. Taking the name
  straight from the URL (`my%20library.blib`) ends in "Missing output file(s)". For the
  single-file downloads only the output declaration and the stub know the decoded name; the
  script, and so the name of its log file (`panorama-get-my%20library.blib.stdout`), is
  unchanged
- a single file is given by the user as a URL, in which a space has to be written as `%20`.
  A literal space is not supported: the client then re-encodes the whole URL, including the
  escapes already in it (`Panorama%20Public` becomes `Panorama%2520Public`), and gets a 404
- MS files are found by listing a directory, and the listing is not URL-encoded, so the
  download URL of `my file.raw` does contain a space. `panorama_request_url` writes it as
  `%20` before the URL is handed to the client by `PANORAMA_GET_MS_FILE` and
  `PANORAMA_PUBLIC_GET_MS_FILE`. Those two have a `storeDir`, so changing their script does
  not make a resumed run download anything again
- replicate metadata on Panorama is fetched by `dia_qc validate` itself, to an output path the
  workflow chooses, and keeps the URL's spelling (`my%20metadata.tsv`). That works and is left
  alone, so as not to rename the files such a run publishes

Not covered: characters other than spaces. A file name with a quote, `$`, a backtick or
another shell metacharacter is not checked and may not work.

## Containers and External Programs

The workflow is containerized and wraps these major tools:

- ProteoWizard / SkylineCmd
- DIA-NN
- EncyclopeDIA
- Cascadia
- Carafe
- Panorama Client
- PDC Client
- DIA QC report tooling
- standard shell utilities such as `md5sum` and `stat`

Container mappings live in `container_images.config`.

## Testing and Validation

The repository includes:

- representative sample configs in `test-resources/`
- Sphinx / Read the Docs documentation sources in `docs/`
- a GitHub Actions workflow at `.github/workflows/push-stub-run.yml`

That workflow runs `nextflow run . -stub-run -c test-resources/<config>` for multiple
configurations, including:

- DIA-NN, with both the 1.8.x and the 2.x output file names
- DIA-NN multi-batch with replicate metadata
- Cascadia
- EncyclopeDIA with and without narrow-window data
- PDC input
- PDC input with batch file
- Carafe multi-file
- no-search mode
- `msconvert_only`

A companion `negative-stub-run` job covers configs that must fail fast, asserting both a
non-zero exit and an expected message fragment. It includes `use_vendor_raw` combined with
`msconvert.do_demultiplex`, `use_vendor_raw` combined with `msconvert_only`, and document
names that cannot be used as file names (`test-document-name-invalid.config` and its
siblings). `test-panorama-no-spectra-match.config` is the one case whose error comes from a
check inside a channel: a batch whose Panorama folder lists no matching file (the stub of
`PANORAMA_PUBLIC_GET_MS_FILE_LIST` returns an empty listing). It is there so that the rule in
"Checks inside channels" cannot silence that check on a healthy run.

Names with spaces are covered by `test-document-name-spaces.config` (document name, through
annotate and minimize, with upload and import) and `test-document-name-spaces-batch.config`
(document name and batch name in multi-batch mode).

Input files with spaces in their names are covered by the `test-input-file-spaces*.config`
family, which uses the files under `test-resources/spaced inputs/`: the DIA-NN path with every
auxiliary input (`test-input-file-spaces.config`, with an upload manifest), EncyclopeDIA with
narrow-window data, a `.blib` library on the DIA-NN path, PDC inputs, Carafe and Cascadia.
`test-pdc-gene-data-spaces.config` is the negative test for the one input that is rejected.
A `script-quoting` job runs `test-resources/check-script-quoting.py`, described under
"Input File Names". As with document names, the stub configs show what Nextflow and the stub
blocks do with the names, not what the tools do; that was established with real runs.

A `slack-stub-run` job covers the opposite guarantee: with `slack.enabled = true` and the
`SLACK_WEBHOOK_URL` secret missing, malformed, or pointing at an unreachable address, the run
must still succeed, log the expected warning, and never print the secret's value. It proves
the failure paths only; no request leaves the runner, so a real delivery to Slack has to be
checked by hand.

This validates branching and workflow wiring, not scientific correctness.

`TESTING.md` is the guide to testing a change: which tests a given change needs, how to run
this suite locally on every Nextflow version in the matrix (`test-resources/run-stub-suite.py`),
and how to do real (non-stub) runs and compare them against `main`
(`test-resources/real-runs/`).

## Project Maintenance Expectations

When making changes to the project, expected maintenance work includes:

- update `nextflow_schema.json` whenever parameters, accepted shapes, or validation rules change
- update relevant documentation in `docs/` whenever user-visible behavior, configuration, or
  workflow structure changes
- update defaults in `nextflow.config` whenever the intended default behavior changes
- add or revise stub configs in `test-resources/` when new branches, options, or regression
  cases need coverage
- run any newly added stub tests after making changes and fix any failures
- update GitHub Actions workflows when the stub-test matrix or CI expectations change
- before considering work complete, run the full stub-test suite and fix any regressions

In practice, the canonical full stub-test suite is the set of configs covered by
`.github/workflows/push-stub-run.yml`.

## High-Value Files When Editing

When modifying behavior, the most useful inspection order is:

1. `main.nf`
2. the relevant file in `workflows/`
3. the relevant file in `subworkflows/`
4. the concrete process wrapper in `modules/`
5. related defaults in `nextflow.config` and `conf/*.config`

For input-resolution changes, start with:

- `subworkflows/get_ms_files.nf`
- `subworkflows/get_input_files.nf`
- `subworkflows/get_replicate_metadata.nf`
- `subworkflows/get_pdc_files.nf`
