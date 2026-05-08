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
  Stub-run coverage for representative branches.

## Main Runtime Flow

### 1. Startup and parameter handling

`main.nf`:

- enables DSL2
- runs `validateParameters()` from `nf-schema`
- maps deprecated Skyline params to nested `params.skyline.*`
- normalizes `search_engine` for local checks
- rejects `panorama.import_skyline` unless Panorama upload is enabled and Skyline is not skipped

Relevant files:

- `main.nf`
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
  surface as opaque join-mismatch errors deeper in the workflow
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
  mzMLs, but may be vendor RAW files or extracted Bruker `.d` directories if those modes
  were selected

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
  directories via `UNZIP_BRUKER_D` and bypass msconvert
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
- optionally runs user-provided `.skyr` reports
- optionally generates QC outputs from Skyline report exports

Batch naming:

- the final document basename is `skyline.document_name`
- in batch mode, batch names are appended as `document_batch`

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
- parsed tool versions
- configured container image names

### Combined file hashes

`subworkflows/combine_file_hashes.nf` builds a combined checksum-and-size table by mixing:

- precomputed search-file stats from the search subworkflow
- calculated md5 values for FASTA files, libraries, Skyline outputs, QC outputs, gene reports,
  report files, and run-details files

Important accuracy note:

- this manifest is not a complete list of every published artifact in the repository
- coverage depends on what each search branch includes in its `search_file_stats`
- currently omitted or inconsistently covered artifacts include:
  - minimized Skyline documents
  - batch-report outputs
  - some search outputs such as final EncyclopeDIA combined outputs and Cascadia `.blib`

### Panorama upload

`subworkflows/panorama_upload.nf` uploads selected outputs under:

- `nextflow/<timestamp>/<workflow.sessionId>/...`

For full analysis runs, Panorama upload includes:

- converted mzML files from `all_mzml_ch`
- run details
- one config file captured by `workflow.configFiles[1]`
- the search FASTA channel used by the active search / Skyline branch
- the user or Carafe spectral library channel
- search files
- final Skyline documents
- `.skyr` input files
- Skyline report outputs
- combined file-hash table

For `msconvert_only` runs, the upload path is smaller and only includes the resolved MS outputs,
run details, and the selected config file.

If `params.panorama.import_skyline` is true, Panorama import runs only after file uploads finish.

Important accuracy note:

- QC reports, batch reports, gene reports, replicate metadata, and Skyline template files are
  not part of Panorama upload in the current implementation

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
- PDC:
  - `pdc.*`
- Carafe:
  - `carafe.*`

Other framework behavior:

- `search_engine` defaults to `encyclopedia`
- optional completion email is sent from `workflow.onComplete` when `params.email` is set and
  mail settings are configured

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

- DIA-NN
- DIA-NN multi-batch with replicate metadata
- Cascadia
- EncyclopeDIA with and without narrow-window data
- PDC input
- PDC input with batch file
- Carafe multi-file
- no-search mode
- `msconvert_only`

This validates branching and workflow wiring, not scientific correctness.

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
