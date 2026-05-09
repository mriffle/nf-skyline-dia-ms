===================================
Workflow Overview
===================================

These documents describe a standardized Nextflow workflow for processing **DIA mass spectrometry
data to quantify peptides and proteins**. The source code for the workflow can be found at:
https://github.com/mriffle/nf-skyline-dia-ms.

This workflow supports three search engines: DIA-NN, Encyclopedia, and Cascadia for performing *de novo* searches.
Each search engine works as a drop-in replacement for the other, supporting all the same pre- and post-analysis steps.
In all cases, the workflow supports converting RAW files, integrating with PanoramaWeb (ProteomeXchange) and Proteomic Data Commons,
and will generate a Skyline document suitable for visualization and analysis in Skyline.

Supported input file formats
===================================
The workflow accepts the following MS input file formats for ``quant_spectra_dir`` and ``chromatogram_library_spectra_dir``:

* ``.mzML`` — supported by all search engines.
* ``.raw`` (Thermo) — supported by all search engines. Files are converted to mzML using *msconvert* unless ``use_vendor_raw`` is enabled.
* ``.d.zip`` (Bruker) — a zipped Bruker ``.d`` directory. The workflow extracts these to ``.d`` directories rather than running *msconvert*. **Bruker ``.d.zip`` input is only supported when ``search_engine`` is ``'diann'`` or ``null`` (no-search, Skyline-only).** EncyclopeDIA and Cascadia do not read Bruker data.

All matched files in a single directory must share one extension; mixing formats within a batch is not supported.

Cascadia workflow:
===================================
The workflow will perform *de novo* identification of peptides using user-supplied DIA RAW (or mzML) files.
The workflow will generate a Skyline document where users may visualize the *de novo* results and export
integrated peak areas for the identified peptides.

DIA-NN workflow:
===================================
The workflow will quantify peptides and proteins using user-supplied DIA RAW, mzML, or Bruker ``.d.zip`` files, a FASTA file, and a spectral
library (optional). If the user does not specify a spectral library, DIA-NN will be run in "library-free" mode, where
it will create its own library using AI. Finally the workflow will generate a Skyline document using the quantified peptides
and proteins.

EncyclopeDIA workflow:
===================================

This workflow is summarized in the following article:

**Chromatogram libraries improve peptide detection and quantification by data independent acquisition mass spectrometry.**
Searle BC, Pino LK, Egertson JD, Ting YS, Lawrence RT, MacLean BX, Villén J, MacCoss MJ. *Nat Commun.* 2018 Dec 3;9(1):5128.
(https://pubmed.ncbi.nlm.nih.gov/30510204/)

The workflow will quantify peptides and proteins using user-supplied DIA RAW (or mzML) files, FASTA file, and spectral
library. If the experimental design includes generation of a chromatogram library using narrow window DIA data, the workflow will
first generate the chromatogram library (Figure 1A) and use that as input to the next phase (Figure 1B) to quantify peptides and
proteins. If the experimental design does not include this, the user-supplied spectral library is used as input for quantifying
peptides and proteins. Finally the workflow will generate a Skyline document using the quantified peptides and proteins.

Other run modes
===================================

* **No-search mode** (``search_engine = null``) — the search step is skipped and the user-supplied ``spectral_library``, ``fasta``, and ``quant_spectra_dir`` files are imported directly into Skyline. Useful when you already have a curated library and only need quantification + Skyline import.
* **msconvert-only mode** (``msconvert_only = true``) — the workflow resolves MS inputs (downloading and converting RAW or extracting Bruker ``.d.zip`` as needed), optionally uploads them to PanoramaWeb, and exits. No search, library generation, or Skyline document is produced.
* **Carafe library generation** (``carafe.spectra_dir`` set, or — when running against PDC — ``carafe.pdc_files`` / ``carafe.pdc_n_files`` set) — Carafe runs before the main search to build a spectral library from your data. The resulting library overrides any user-supplied ``spectral_library``. With PDC input, Carafe consumes a subset of the PDC quant download (no separate upload required).
* **PDC input** (``pdc.study_id`` set) — RAW or Bruker ``.d.zip`` files and study metadata are downloaded from the Proteomic Data Commons instead of from local/Panorama paths. Outside ``msconvert_only`` mode, PDC requires ``search_engine = 'diann'``.

The workflow is summarized graphically as:

.. figure:: /_static/workflow_figure.png
   :class: with-border

   Figure 1. An overview of the computational pipeline implemented by this workflow. (A) the optional
   generation of a chromatogram library that can be fed into part (B) for peptide and
   protein quantification using DIA. If part (A) is not run, a user-supplied spectral library
   or chromatogram library may be used for quantification in part (B).

How to Run
===================
This workflow uses the Nextflow standardized workflow platform. The Nextflow platform emphasizes ease of use, workflow portability,
and containerization of the individual steps. To run this workflow, **you do not need to install any of the software components of
the workflow**. There is no need to worry about installing necessary software libraries, version incompatibilities, or compiling or
installing complex and fickle software.

To run the workflow you need only install Nextflow, which is relatively simple. To run the individual steps of the workflow on your
own computer, you will need to install Docker. After these are installed, you will need to edit the pipeline configuration file to
supply the locations of your data and execute a simple Nextflow command, such as:

.. code-block:: bash

    nextflow run -resume -r main mriffle/nf-skyline-dia-ms -c pipeline.config

The entire workflow will be run automatically, downloading Docker images as necessary, and the results output to
the ``results`` directory. See :doc:`how_to_install` for more details on how to install Nextflow and Docker. See
:doc:`how_to_run` for more details on how to run the workflow. And see :doc:`results` for more details on how to
retrieve the results.


Workflow Components
===================
The workflow is made up of the following software components, each may be run multiple times for different tasks.

*  **PanoramaWeb** (https://panoramaweb.org/home/project-begin.view)

   Users may optionally use WebDAV URLs as locations for input data files in PanoramaWeb. The workflow will automatically download files as necessary.

*  **msconvert** (https://proteowizard.sourceforge.io/)

   If users supply RAW files as input, they will be converted to mzML using *msconvert* (unless ``use_vendor_raw`` is set).
   Bruker ``.d.zip`` inputs bypass *msconvert* and are extracted to ``.d`` directories that are passed directly to DIA-NN or Skyline.

*  **EncyclopeDIA** (http://www.searlelab.org/software/encyclopedia/index.html)

   When ``search_engine = 'encyclopedia'``, *EncyclopeDIA* is used in three parts of the pipeline:

      1. If the user supplies a *BLIB* spectral library, *EncyclopeDIA* will be used to convert that to a *DLIB*.
      2. *EncyclopeDIA* is used to search narrow window DIA data and generate a chromatogram library.
      3. *EncyclopeDIA* is used to quantify peptides and proteins.

*  **DIA-NN** (https://github.com/vdemichev/DiaNN)

   When ``search_engine = 'diann'``, *DIA-NN* performs the search. It can use a user-supplied spectral library, a Carafe-generated library, or run in library-free mode where it predicts a library from the FASTA. DIA-NN is the only search engine that supports Bruker ``.d.zip`` input and multi-batch runs.

*  **Cascadia** (https://github.com/Noble-Lab/Cascadia)

   When ``search_engine = 'cascadia'``, *Cascadia* performs *de novo* peptide identification and produces its own spectral library and FASTA. User-supplied spectral libraries are ignored and batch mode is not supported.

*  **Carafe** (https://github.com/Noble-Lab/Carafe)

   Optionally generates a spectral library before the main search when ``carafe.spectra_dir`` (or the legacy ``carafe.spectra_file``) is set. The generated library overrides any user-supplied ``spectral_library`` for downstream search. Carafe accepts ``.mzML``, ``.raw``, and Bruker ``.d.zip`` inputs; ``.raw`` files are converted to mzML and ``.d.zip`` files are extracted to ``.d`` directories before Carafe runs.

*  **PDC Client** (https://proteomic.datacommons.cancer.gov/)

   When ``pdc.study_id`` is set, the workflow downloads RAW or Bruker ``.d.zip`` files and study metadata from the Proteomic Data Commons. PDC studies are searched with DIA-NN (the only search engine compatible with the PDC branch outside ``msconvert_only`` mode).

*  **Skyline** (https://skyline.ms/project/home/begin.view)

   *Skyline* imports MS data and search results from any of the three search engines (or the user-supplied library in no-search mode) into a Skyline template document. The document is annotated with replicate metadata, optionally minimized, and used to run any user-supplied ``.skyr`` reports.

*  **DIA-QC report tooling** (https://github.com/ajmaurais/DIA_QC_report)

   When ``qc_report.skip`` is ``false``, this tooling generates a normalized precursor/protein quality report (HTML and/or PDF) from Skyline report exports. Batch reports and PDC gene-level reports use the same database.
