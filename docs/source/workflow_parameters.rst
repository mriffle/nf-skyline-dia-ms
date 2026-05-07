===================================
Workflow Parameters
===================================

The workflow parameters should be included in a configuration file, an example
of which can be found at
https://raw.githubusercontent.com/mriffle/nf-skyline-dia-ms/main/resources/pipeline.config

The parameters in this file should be changed to indicate the locations of your data, the
options you'd like to use for the software included in the workflow, and the capabilities and
configuration for the system on which you are running the workflow steps.

The configuration file is roughly organized as:

.. code-block:: groovy

    params {
    ...
    }

    profiles {
    ...
    }

    mail {
    ...
    }

- The ``params`` section includes locations of data and configuration options for a specific run of the workflow.
- The ``profiles`` sections includes parameters that describe the capabilities of the systems that run the steps of the workflow. For example, if running on your local system, this will include things like how many cores and how much RAM may be used by the steps of the workflow. This will not need to be changed for each run of the workflow.
- The ``mail`` section includes configuration options for sending email. This is optional and only necessary if you wish to send emails when the workflow completes. This will not need to be changed for each run of the workflow.

Below is a complete description of all parameters that may be included in these sections.

.. note::

    This workflow can process files stored in **PanoramaWeb**. When specifying directories or file locations, any paths that begin with ``https://`` will be interpreted as being PanoramaWeb locations.

    For example, to process raw files stored in PanoramaWeb, you would have the following in your pipeline.config file:

    .. code-block:: bash

        quant_spectra_dir= 'https://panoramaweb.org/_webdav/path/to/@files/RawFiles/'


    Where, ``https://panoramaweb.org/_webdav/path/to/@files/RawFiles/`` is the WebDav URL of the folder on the Panorama server.


The ``params`` Section
^^^^^^^^^^^^^^^^^^^^^^^

.. list-table:: Parameters for the ``params`` section
   :widths: 5 20 75
   :header-rows: 1

   * - Req?
     - Parameter Name
     - Description
   * -
     - ``spectral_library``
     - That path to the spectral library to use. May be a ``dlib``, ``elib``, ``blib``, ``speclib`` (DIA-NN), ``tsv`` (DIA-NN), or other formats supported by EncyclopeDIA or DIA-NN. If a Carafe library is being generated the Carafe spectral library will override this parameter. This parameter is required for EncyclopeDIA. If omitted when using DIA-NN, DIA-NN will be run in library-free mode. This parameter is ignored when running Cascadia.
   * -
     - ``fasta``
     - The path to the background FASTA file to use. This parameter is required, except when running Cascadia.
   * - ✓
     - ``quant_spectra_dir``
     - The path to the directory containing the raw data to be quantified. If using narrow window DIA and GPF to generated a chromatogram library this is the location of the wide-window data to be searched using the chromatogram library.
       Supported file formats are ``.mzML``, ``.raw`` (Thermo), and ``.d.zip`` (Bruker). All matched files must share a single extension. Bruker ``.d.zip`` is only compatible with ``search_engine = 'diann'`` or ``search_engine = null``; EncyclopeDIA and Cascadia do not read Bruker data.
   * -
     - ``quant_spectra_glob``
     - Which files in this directory to use. Default: ``*.raw``
   * -
     - ``quant_spectra_regex``
     - Use this regex instead of ``quant_spectra_glob`` to select files in ``quant_spectra_dir``.
       If set, ``quant_spectra_glob`` must be set to ``null``. Default: ``null``.
   * -
     - ``files_per_quant_batch``
     - Randomly select ``n`` files per batch in ``quant_spectra_dir``. If ``null`` all the files in ``quant_spectra_dir`` are used. Default is ``null``.
   * -
     - ``chromatogram_library_spectra_dir``
     - If you are creating a chromatogram library using GPF and narrow window DIA, this is the path to the directory containing the narrow-window raw data.
       Accepts the same file formats as ``quant_spectra_dir``, with the same per-engine restrictions (Bruker ``.d.zip`` only with DIA-NN; EncyclopeDIA narrow-window searches require ``.mzML`` or ``.raw``).
   * -
     - ``chromatogram_library_spectra_glob``
     - Which files in this directory to use. Default: ``*.raw``
   * -
     - ``chromatogram_library_spectra_regex``
     - Use this regex instead of ``chromatogram_library_spectra_glob`` to select files in ``chromatogram_library_spectra_dir``.
       If set, ``chromatogram_library_spectra_glob`` must be set to ``null``. Default: ``null``.
   * -
     - ``use_vendor_raw``
     - If supported by the ``search_engine``, skip the ``MSCONVERT`` step to generate mzMLs and use vendor raw files for the search and to generate the Skyline document.
       Default is ``false``.
   * -
     - ``vendor_raw_copy``
     - If `use_vendor_raw` is set to true, Nextflow will attempt to use hard links to the raw file, which is required by vendor libraries. However, this is not supported in all environment. If hard links are not supported, set this to true to create physical copies of the files instead of hard links. This will use extra space.
       Default is ``false``.
   * -
     - ``files_per_chrom_lib``
     - Randomly select ``n`` files in ``chromatogram_library_spectra_dir`` to use to build chromatogram library. If ``null`` all the files in ``chromatogram_library_spectra_dir`` are used. Default is ``null``.
   * -
     - ``random_file_seed``
     - The seed used to randomly select files for the ``files_per_chrom_lib`` and ``files_per_quant_batch`` parameters. A seed is used so that if the workflow is re-run the same sequence of files will be randomly selected each time. Default is ``12``.
   * -
     - ``search_engine``
     - Must be set to either ``'encyclopedia'``, ``'diann'``, ``'cascadia'``, or ``null``.
       If set to ``'cascadia'``, ``chromatogram_library_spectra_dir``, ``chromatogram_library_spectra_glob``, and EncyclopeDIA-specific parameters will be ignored.
       If set to ``null``, the workflow will skip the search step and generate Skyline document(s) using ``spectral_library``, ``fasta``, and files in ``quant_spectra_dir``.
       Bruker ``.d.zip`` MS input is only supported with ``'diann'`` or ``null``; ``'encyclopedia'`` and ``'cascadia'`` require ``.mzML`` or ``.raw`` input.
       When ``pdc.study_id`` is set and ``msconvert_only`` is ``false``, this must be ``'diann'``.
       Default: ``'encyclopedia'``.
   * -
     - ``replicate_metadata``
     - Metadata annotations for each ``raw`` or ``mzML`` file. Can be in ``tsv`` or ``csv`` format. See the :ref:`replicate_metadata` section for details of how the file should be formatted. If a metadata file is specified it will be used to add annotations to the final Skyline document and can be used to color PCA plots in the QC report by specifying the ``qc_report.color_vars`` parameter. If this parameter is set to ``null`` the skyline document annotation step is skipped.
   * -
     - ``msconvert_only``
     - If set to ``true``, the workflow resolves MS inputs (downloading and converting RAW or extracting Bruker ``.d.zip`` as needed), optionally uploads them to PanoramaWeb if ``panorama.upload`` is also set, and then exits. No search, Skyline document, QC report, or library generation is performed. Useful for pre-staging mzML files. Default: ``false``.
   * -
     - ``email``
     - The email address to which a notification should be sent upon workflow completion. If no email is specified, no email will be sent. To send email, you must configure mail server settings (see below).


``params.pdc``
==============

.. list-table:: Parameters for getting raw files and metadata from the Proteomics Data Commons. All parameters in this section are optional.
   :widths: 20 80
   :header-rows: 1

   * - Parameter Name
     - Description
   * - ``pdc.study_id``
     - When this option is set, raw files and metadata will be downloaded from the PDC. Default: ``null``.
       When the PDC branch is used and ``msconvert_only`` is ``false``, ``search_engine`` must be set to ``'diann'``; EncyclopeDIA, Cascadia, and no-search mode are not supported with PDC input.
   * - ``pdc.metadata_tsv``
     - Path to a pre-downloaded PDC study metadata file (``tsv``). When set, the workflow uses this file directly instead of fetching study metadata via the PDC API. Useful for offline runs or when the PDC API is slow/unavailable. Default: ``null``.
   * - ``pdc.study_name``
     - Override the study name used when ``pdc.metadata_tsv`` is supplied. If ``null``, the value of ``pdc.study_id`` is used. Default: ``null``.
   * - ``pdc.gene_level_data``
     - A ``tsv`` file mapping gene names to NCIB gene IDs and gene metadata. Required for PDC gene reports. Default: ``null``.
   * - ``pdc.n_raw_files``
     - If this option is set, only ``n`` raw files are downloaded. This is useful for testing but otherwise should be ``null``.
   * - ``pdc.client_args``
     - Additional command line arguments passed to ``PDC_client``. Default is ``null``.
   * - ``pdc.s3_download``
     - If set to ``true`` download raw files through an S3 transfer instead of over https.
       This option will only work if the workflow execution environment is configured to directly access PDC AWS infrastructure.
       Default is ``false``.
   * - ``pdc.batch_file``
     - A ``tsv`` file that assigns each PDC file to a named batch. The file must have ``file_name`` and ``batch`` columns. When set, the workflow produces a separate Skyline document per batch, following the same multi-batch behavior as when ``quant_spectra_dir`` is a ``Map``. All files in the batch file must match files downloaded from the PDC study, and all downloaded files must be present in the batch file. Default: ``null``.


``params.carafe``
=================

.. list-table:: Parameters for Carafe. All parameters in this section are optional.
   :widths: 20 80
   :header-rows: 1

   * - Parameter Name
     - Description
   * - ``carafe.spectra_file``
     - Legacy direct ``raw``, ``mzML``, or Bruker ``.d.zip`` file input used by Carafe to generate the final spectral library. This remains supported for backwards compatibility. ``.raw`` files are converted to mzML by *msconvert*; ``.d.zip`` files are extracted to a ``.d`` directory and passed directly to Carafe. If set together with ``carafe.spectra_dir`` the workflow will fail. Default: ``null``.
   * - ``carafe.spectra_dir``
     - Directory, or list of directories, containing the ``raw``, ``mzML``, or Bruker ``.d.zip`` files to use for Carafe. All matched files must share a single extension. Carafe will run once across all matching files. ``.d.zip`` files bypass *msconvert* and are extracted to ``.d`` directories. If set to ``null`` and ``carafe.spectra_file`` is also ``null``, Carafe is skipped. Default: ``null``.
   * - ``carafe.spectra_glob``
     - Glob used to select files in ``carafe.spectra_dir``. Only ``*`` is treated as a wildcard. If set, ``carafe.spectra_regex`` must be ``null``. Default: ``*.raw``.
   * - ``carafe.spectra_regex``
     - Use this regex instead of ``carafe.spectra_glob`` to select files in ``carafe.spectra_dir``. If set, ``carafe.spectra_glob`` must be ``null``. Default: ``null``.
   * - ``carafe.peptide_results_file``
     - The path to a DIA-NN ``tsv`` or ``parquet`` precursor report file. If this parameter is set, the DIA-NN search will be skipped and this file used. Default: ``null`` (run DIA-NN).
   * - ``carafe.carafe_fasta``
     - FASTA file used by Carafe to generate final spectral library. If ``null``, ``params.fasta`` is used.
   * - ``carafe.cli_options``
     - Command line options to pass to Carafe. Note: Do not set the ``-mode``, ``-varMod``, ``-maxVar``, ``-ms``, ``-db``, ``-i``, ``-se``, ``-lf_type``, ``-device`` parameters, these are handled by the workflow. The default is ``-fdr 0.01 -ptm_site_prob 0.75 -ptm_site_qvalue 0.01 -itol 20 -itolu ppm -rf -rf_rt_win auto -cor 0.8 -min_mz 200 -n_ion_min 2 -c_ion_min 2 -enzyme 2 -miss_c 1 -fixMod 1 -clip_n_m -minLength 7 -maxLength 35 -min_pep_mz 300 -max_pep_mz 1800 -min_pep_charge 2 -max_pep_charge 4 -lf_frag_mz_min 200 -lf_frag_mz_max 1800 -lf_top_n_frag 20 -lf_min_n_frag 2 -lf_frag_n_min 2 -tf all -nm -nf 4 -min_n 4 -valid -na 0 -ez -fast``
       See the `Carafe GitHub page <https://github.com/Noble-Lab/Carafe>`_ for details on available parameters.
   * - ``carafe.include_phosphorylation``
     - Set to ``true`` to include phosphoylation of S, T, Y in your spectral library. Default: ``false``
   * - ``carafe.include_oxidized_methionine``
     - Set to ``true`` to include oxidation of M in your spectral library. Default: ``false``
   * - ``carafe.max_mod_option``
     - The number of variable modifications allowed per peptide. Ignore if no variable modifications are include. Default: ``-maxVar 1``
   * - ``carafe.diann_fasta``
     - The FASTA file used by the DIA-NN search in the Carafe subworkflow. If not set either ``params.carafe_fasta`` or ``params.fasta`` will be used. Default: ``null``.

``params.msconvert``
====================

.. list-table:: Parameters for Msconvert. All parameters in this section are optional.
   :widths: 20 80
   :header-rows: 1

   * - Parameter Name
     - Description
   * - ``msconvert.do_demultiplex``
     - If starting with raw files, this is the value used by ``msconvert`` for the ``do_demultiplex`` parameter. Default: ``true``.
   * - ``msconvert.do_simasspectra``
     - If starting with raw files, this is the value used by ``msconvert`` for the ``do_simasspectra`` parameter. Default: ``true``.
   * - ``msconvert.mz_shift_ppm``
     - If starting with raw files, ``msconvert`` will shift all mz values by ``n`` ppm when converting to ``mzML``. If ``null`` the mz values are not shifted. Default: ``null``.



``params.diann``
================

When using DIA-NN, the ``chromatogram_library_spectra_dir`` parameter can optionally be used to create a subset library.
The files in ``chromatogram_library_spectra_dir`` are searched first using a spectral library either specified by ``params.spectral_library``, or a predicted library generated in the workflow by Carafe or DiaNN.
Then, the resulting subset library containing only those precursors identified in the first search, is then used to search the files in ``quant_spectra_dir``.

DIA-NN requires at least 2 MS files in each search input.
This applies to ``quant_spectra_dir``, and (when configured) also to ``chromatogram_library_spectra_dir``.
The match-between-runs step (``DIANN_MBR``) needs two or more runs to emit the spectral library used downstream;
the workflow will fail with an explicit error naming which input(s) are too small when fewer files are supplied.

.. list-table:: Parameters for DIA-NN. All parameters in this section are optional.
   :widths: 20 80
   :header-rows: 1

   * - Parameter Name
     - Description
   * - ``diann.search_params``
     - The parameters passed to DIA-NN when it is run. Default: ``'--qvalue 0.01'``
       Note: Do not set the ``--fasta``, ``--lib``, ``--threads``, ``--use-quant``, ``--gen-spec-lib``, ``--reanalyse``, ``--rt-profiling``, or ``--id-profliing``, parameters.
       These parameters are are handled by the ``DIANN_QUANT`` and ``DIANN_MBR`` processes.
   * - ``diann.fasta_digest_params``
     - Parameters used when generateing predicted spectral library with DIA-NN.
       Note: Do not set the ``--fasta``, ``--predictor``, ``--gen-spec-lib``, ``--fasta-search``, or ``--out-lib`` parameters.
       These parameters are are handled by the ``DIANN_BUILD_LIB`` process.

       Default is: ``'--cut \'K*,R*,!*P\' --unimod4 --missed-cleavages 1 --min-pep-len 8 --min-pr-charge 2 --max-pep-len 30'``


``params.encyclopedia`` and ``params.cascadia``
===============================================

.. list-table:: Parameters for EncyclopeDIA and Cacsadia. All parameters in this section are optional.
   :widths: 20 80
   :header-rows: 1

   * - Parameter Name
     - Description
   * - ``encyclopedia.chromatogram.params``
     - If you are generating a chromatogram library for quantification, this is the command line options passed to EncyclopeDIA during the chromatogram generation step. Default: ``'-enableAdvancedOptions -v2scoring'`` If you do not wish to pass any options to EncyclopeDIA, this must be set to ``''``.
   * - ``encyclopedia.quant.params``
     - The command line options passed to EncyclopeDIA during the quantification step. Default: ``'-enableAdvancedOptions -v2scoring'`` If you do not wish to pass any options to EncyclopeDIA, this must be set to ``''``.
   * - ``encyclopedia.save_output``
     - EncyclopeDIA generates many intermediate files that are subsequently processed by the workflow to generate the final results. These intermediate files may be large. If set to ``true``, all intermediate files are saved in your ``results`` directory; if ``false``, only ``stdout``/``stderr`` logs are saved (the final ``.elib`` is always saved regardless). Default: ``true``.
   * - ``cascadia.use_gpu``
     - If set to ``true``, Cascadia will attempt to use the GPU(s) installed on the system where it is running. Do not set to true unless a GPU is available, otherwise an error will be gernated. Default: ``false``.
   * - ``cascadia.score_threshold``
     - Score threshold applied to Cascadia predictions. Must be between 0 and 1. Default: ``0.8``.

Cascadia has additional behavioral constraints worth knowing:

- Multi-batch mode is not supported. Setting ``quant_spectra_dir`` to a ``Map`` (or using ``pdc.batch_file``) with ``search_engine = 'cascadia'`` will cause the workflow to fail at startup.
- Any user-supplied ``spectral_library`` is ignored with a warning. Cascadia performs *de novo* identification and produces its own library.
- Cascadia generates its own FASTA from identified sequences; ``params.fasta`` is not required when running Cascadia.


``params.skyline``
==================

.. list-table:: Parameters for the ``params.skyline`` section. All parameters in this section are optional.
   :widths: 20 80
   :header-rows: 1

   * - Parameter Name
     - Description
   * - ``skyline.skip``
     - If set to ``true``, will skip the creation of a Skyline document. Default: ``false``.
   * - ``skyline.document_name``
     - The base of the file name of the generated Skyline document. If set to ``'human_dia'``, the output file name would be ``human_dia.sky.zip``. Note: If importing into PanoramaWeb, this is also the name that appears in the list of imported Skyline documents on the project page. Default: ``final``.
   * - ``skyline.skyr_file``
     - Path(s) (local file system or Panorama WebDAV) to a ``.skyr`` file, which is a Skyline report template. Any reports specified in the ``.skyr`` file will be run automatically as the last step of the workflow and the results saved in your ``results`` directory and (if requested) uploaded to Panorama. The report template(s) can be a single string, or for multiple ``.skyr`` files can be given as a list of strings.
       For example: ``'/path/to/report.skyr'`` for a single file, or
       ``['/path/to/report_1.skyr', '/path/to/report_2.skyr']`` for multiple files.
   * - ``skyline.template_file``
     - The Skyline template file used to generate the final Skyline file. By default a
       pre-made Skyline template file suitable for EncyclopeDIA or DIA-NN will be used. Specify a file
       location here to use your own template. Note: The filenames in the .zip file must match
       the name of the zip file, itself. E.g., ``my-skyline-template.zip`` must contain ``my-skyline-template.sky``.
   * - ``skyline.group_proteins``
     - If ``true``, peptides are grouped into proteins in Skyline. Default is ``false``.
   * - ``skyline.protein_parsimony``
     - If ``true``, protein parsimony is performed in Skyline. If ``false`` the protein assignments given by the search engine are used as protein groups. Default is ``false``.
   * - ``skyline.fasta``
     - The fasta file to use as a background proteome in Skyline. If ``null`` the same fasta file (``params.fasta``) used for the DIA search is used. Default is ``null``.
   * - ``skyline.group_by_gene``
     - If ``true``, when protein parsimony is performed in Skyline protein groups are formed by gene instead of by protein. Default is ``false``.
   * - ``skyline.minimize``
     - If ``true``, the size of the final Skyline document is minimized. Chromatograms for isotopic peaks that are not in the document are removed from the ``skyd`` file and a minimal spectral library is generated by removing spectra that are not in the document. Default is ``false``.
   * - ``skyline.use_hardlinks``
     - On systems that allow it, setting this to ``true`` allows the use of cached Skyline workflow steps and may improve performance on subsequent runs. Note: some systems do not allow this, which will result in an error. Default: ``false``.


``params.qc_report`` and ``params.batch_report``
================================================

.. list-table:: Parameters for QC and batch reports. All parameters in this section are optional.
   :widths: 20 80
   :header-rows: 1

   * - Parameter Name
     - Description
   * - ``qc_report.skip``
     - If set to ``true``, will skip the creation of a the QC report. Default: ``true``.
   * - ``qc_report.normalization_method``
     - Normalization method to use for plots in QC and batch report(s). This option applies to both the QC and batch reports. Available options are ``DirectLFQ`` and ``median``.
       Default is ``median``.
   * - ``qc_report.imputation_method``
     - Method to use to impute missing precursor peak areas for plots in QC and batch report(s).
       This option applies to both the QC and batch reports.
       Available options are ``KNN``. If set to ``null`` imputation of peaks areas is not performed. Default is ``null``.
   * - ``qc_report.standard_proteins``
     - List of protein names in Skyline document to plot retention times for.

       For example: ``['iRT', 'sp|P00924|ENO1_YEAST']``

       If ``null``, the standard protein retention time plot is skipped. Default is ``null``.
   * - ``qc_report.color_vars``
     - List of metadata variables to color PCA plots by.

       For example: ``['sample_type', 'strain']``

       This option applies to both the QC and batch reports.
       If ``null``, only a single PCA plot colored by file acquisition order is generated.
       Default is ``null``.
   * - ``qc_report.export_tables``
     - Export tsv files containing normalized precursor and protein quantities? Default is ``false``.
   * - ``qc_report.report_format``
     - List of formats to render the QC report in. Allowed values are ``'html'`` and ``'pdf'``; either or both may be included. Default: ``['html']``.
   * - ``qc_report.exclude_replicates``
     - List of replicate names to exclude from normalization and batch correction. Default: ``null``.
   * - ``qc_report.exclude_projects``
     - List of batch/project names to exclude from normalization and batch correction. Default: ``null``.
   * - ``batch_report.skip``
     - If set to ``true``, will skip the creation of a the batch report. Default: ``true``.
   * - ``batch_report.batch1``
     - Metadata key for batch level 1. If ``null``, the project name in ``documents`` is used as the batch variable.
   * - ``batch_report.batch2``
     - Metadata key for batch level 2. A second batch level is only supported with ``limma`` as the batch correction method.
   * - ``batch_report.covariate_vars``
     - Metadata key(s) to use as covariates for batch correction.  If ``null``, no covariates are used.
   * - ``batch_report.control_key``
     - Metadata key indicating replicates which are controls for CV plots. If ``null``, all replicates are used in CV distribution plot.
   * - ``batch_report.control_values``
     - Metadata value(s) mapping to ``control_key`` indicating whether a replicate is a control.
   * - ``batch_report.plot_ext``
     - File extension for standalone plots. If ``null``, no standalone plots are produced.


``params.panorama``
===================

.. list-table:: Parameters for uploading pipeline results to PanoramaWeb. All parameters in this section are optional.
   :widths: 20 80
   :header-rows: 1

   * - Parameter Name
     - Description
   * - ``panorama.upload``
     - Whether or not to upload results to PanoramaWeb Default: ``false``.
   * - ``panorama.upload_url``
     - The WebDAV URL of a directory in PanoramaWeb to which to upload the results. Note that ``panorama.upload`` must be set to ``true`` to upload results.
   * - ``panorama.import_skyline``
     - If set to ``true``, the generated Skyline document will be imported into PanoramaWeb's relational database for inline visualization. The import will appear in the parent folder for the ``panorama.upload_url`` parameter, and will have the name used for the ``skyline.document_name`` parameter. Default: ``false``. Note: ``panorama.upload`` must be set to ``true`` and ``skyline.skip`` must be set to ``false`` to use this feature.


Running the workflow in multi-batch mode
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The workflow can be run in multi-batch mode if the ``params.search_engine`` supports it.
Among the search engines, only ``'diann'`` supports multi-batch mode; EncyclopeDIA and Cascadia raise an error at startup if invoked with batch inputs (a ``Map``-shaped ``quant_spectra_dir`` or a ``pdc.batch_file``). No-search mode (``search_engine = null``) also accepts batch inputs and produces one Skyline document per batch.

There are two ways to activate multi-batch mode:

Using ``quant_spectra_dir`` as a Map
====================================

For non-PDC runs, ``params.quant_spectra_dir`` must be a ``Map`` where each key, value pair is a batch name and the ms files corresponding to the batch.
For example:

.. code-block:: groovy

    params {
      quant_spectra_dir = ['Plate_1': '<path to mzML/raw files>',
                           'Plate_2': '<path to mzML/raw files>']
    }


**Note:** mzML/raw file names can not be duplicated in any batch. If there are duplicate file names the ``DIANN_MBR`` process will fail.

Using ``pdc.batch_file`` for PDC runs
=====================================

For PDC runs, multi-batch mode is activated by setting ``params.pdc.batch_file`` to a ``tsv`` file that assigns each downloaded PDC file to a batch. The file must have ``file_name`` and ``batch`` columns:

.. list-table:: Example PDC batch file format
   :widths: 50 50
   :header-rows: 1

   * - file_name
     - batch
   * - sample_001.raw
     - BatchA
   * - sample_002.raw
     - BatchA
   * - sample_003.raw
     - BatchB
   * - sample_004.raw
     - BatchB

The workflow validates that all files in the batch file match files downloaded from the PDC study, and that all downloaded files appear in the batch file.

For example:

.. code-block:: groovy

    params {
      pdc.study_id = 'PDC000504'
      pdc.batch_file = '/path/to/pdc_batches.tsv'
    }


Differences in result files in multi batch mode
================================================

- A separate Skyline document is generated for each batch, with the batch name appended to the document name.

  * For example, if ``params.skyline.document_name`` is ``'human_dia'`` and using the batches in the example above, 2 documents would be generated:

    #. ``human_dia_Plate_1.sky.zip``
    #. ``human_dia_Plate_2.sky.zip``

  * For PDC runs where ``skyline.document_name`` defaults to the study name, the batch name is appended similarly:

    #. ``study_name_BatchA.sky.zip``
    #. ``study_name_BatchB.sky.zip``

- Any optional Skyline reports will be generated separately for each document.
- A separate QC report is generated for each Skyline document.
- If results are uploaded to PanoramaWeb, any ``mzML`` files generated in the workflow are put into a separate subdirectory for each batch.

.. _replicate_metadata:

Providing replicate metadata
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The ``replicate_metadata`` file can be a ``tsv`` or ``csv`` file where the first column has the header ``Replicate``. The values under the replicate column should match exactly the names of the mzML or raw files which will be in the Skyline document. The headers of subsequent columns are the names of each metadata variable and the values in each column are the annotations corresponding to each replicate.

.. list-table:: Example replicate metadata file format
   :widths: 20 20 20
   :header-rows: 1

   * - Replicate
     - sample_type
     - strain
   * - replicate_1.raw
     - test
     - BALB/cJ
   * - replicate_2.raw
     - test
     - C57BL/6J
   * - replicate_3.raw
     - IBQC
     - Pool


The ``profiles`` Section
^^^^^^^^^^^^^^^^^^^^^^^^
The example configuration file includes this ``profiles`` section:

.. code-block:: groovy

    profiles {

        // "standard" is the profile used when the steps of the workflow are run
        // locally on your computer. These parameters should be changed to match
        // your system resources (that you are willing to devote to running
        // workflow jobs).
        standard {
            params.max_memory = '8.GB'
            params.max_cpus = 4
            params.max_time = '240.h'

            params.mzml_cache_directory = '/data/mass_spec/nextflow/nf-skyline-dia-ms/mzml_cache'
            params.panorama_cache_directory = '/data/mass_spec/nextflow/panorama/raw_cache'
        }
    }

These parameters describe the capability of your local computer for running the steps of the workflow. Below is a description of each parameter:

.. list-table:: Parameters for the ``profiles/standard`` section
   :widths: 5 20 75
   :header-rows: 1

   * - Req?
     - Parameter Name
     - Description
   * - ✓
     - ``params.max_memory``
     - The maximum amount of RAM that may be used by steps of the workflow. Default: 8 gigabytes.
   * - ✓
     - ``params.max_cpus``
     - The number of cores that may be used by the workflow. Default: 4 cores.
   * - ✓
     - ``params.max_time``
     - The maximum amount of a time a step in the workflow may run before it is stopped and error generated. Default: 240 hours.
   * - ✓
     - ``params.mzml_cache_directory``
     - When ``msconvert`` converts a RAW file to mzML, the mzML file is cached for future use. This specifies the directory in which the cached mzML files are stored.
   * - ✓
     - ``params.panorama_cache_directory``
     - If the RAW files to be processed are in PanoramaWeb, the RAW files will be downloaded to and cached in this directory for future use.


The ``process`` Section
^^^^^^^^^^^^^^^^^^^^^^^

In Nextflow the default compute resources allocated to a process can be adjusted in the ``process`` section using the ``withName`` selector.
The following processes will dynamically adjust the requested memory and run time to fit the number and size of the files being processed.
Nextflow will try to allocate resources using the formulas below up to the maximum values specified by ``params.max_memory``, ``params.max_time`` and ``params.max_cpus``.

.. list-table:: Default resources for processes with custom labels
   :widths: 15 5 50 30
   :header-rows: 1

   * - Process
     - CPUs
     - Memory
     - Walltime
   * - ``DIANN_QUANT``
     - 8
     - Maximum of 16 GB and 2 times the sum of the sizes of the MS and spectral library files
     - 2 hours
   * - ``DIANN_MBR``
     - 32
     - Maximum of 32 GB and 2 times the sum of the MS file sizes
     - 10 minutes times the number of MS files
   * - ``BLIB_BUILD_LIBRARY``
     - 2
     - Maximum of 8 GB and 1.5 times the size of the precursor report file
     - 2 hours
   * - ``ENCYCLOPEDIA_SEARCH_FILE``
     - 8
     - 16 GB
     - 4 hours
   * - ``ENCYCLOPEDIA_CREATE_ELIB``
     - 32
     - Maximum of 32 GB and 4 times the number of MS files
     - 24 hours
   * - ``SKYLINE_ADD_LIB``
     - 8
     - Maximum of 8 GB and 10 times the spectral library size
     - 4 hours
   * - ``SKYLINE_IMPORT_MS_FILE``
     - 8
     - Maximum of 8 GB and the sum of the MS file and skyline template with spectral library
     - 2 hours
   * - ``SKYLINE_MERGE_RESULTS``
     - 32
     - Maximum of 8 GB and 1.5 times the sum of the sizes of the .skyd files
     - 8 hours
   * - ``SKYLINE_ANNOTATE_DOCUMENT``
     - 8
     - Maximum of 8 GB and 1.5 times the size of the skyline zip file
     - 4 hours
   * - ``SKYLINE_RUN_REPORTS``
     - 8
     - Maximum of 8 GB and 1.5 times the size of the skyline zip file
     - 4 hours
   * - ``MERGE_REPORTS``
     - 2
     - Maximum of 8 GB and the sum of the sizes of the precursor reports
     - 8 hours
   * - ``FILTER_IMPUTE_NORMALIZE``
     - 8
     - Maximum of 8 GB and 2 times the size of the batch database
     - 4 hours
   * - ``GENERATE_QC_QMD``
     - 2
     - Maximum of 8 GB and 2 times the size of the batch database
     - 2 hours
   * - ``GENERATE_BATCH_REPORT``
     - 2
     - Maximum of 8 GB and 2 times the size of the batch database
     - 4 hours
   * - ``EXPORT_TABLES``
     - 2
     - Maximum of 8 GB and 2 times the size of the batch database
     - 2 hours
   * - ``RENDER_QC_REPORT``
     - 2
     - Maximum of 8 GB and 2 times the size of the batch database
     - 2 hours
   * - ``EXPORT_GENE_REPORTS``
     - 2
     - Maximum of 8 GB and 2 times the size of the batch database
     - 2 hours

In most cases there is no need for users to adjust the default values.
One instance where adjusting these parameters could be useful is to select the AWS batch queue to be used for a specific process.
The ``DIANN_MBR`` process downloads all MS files to a single EC2 instance.
In cases where large numbers of files are being processed the available disk space on the default EC2 instance might not be sufficient to hold all the MS files.
The ``DIANN_MBR`` process can be set to run in a queue with more disk space by adding the following to the pipeline config.

.. code-block:: groovy

    process {
       withName:DIANN_MBR {
           queue = "nextflow_basic_ec2_1tb"
       }
   }

The resource requirements allocated to a process can be fully customized by adding a ``withName`` selector to the ``process`` section of the pipeline config file.
For example, to override the default memory and wall time for ``DIANN_MBR`` you could add the following to the pipeline config:

.. code-block:: groovy

    process {
        withName:DIANN_MBR {
            memory = 248.GB
            time = 48.h
        }
    }


The ``mail`` Section
^^^^^^^^^^^^^^^^^^^^^^^
This is a more advanced and entirely optional set of parameters. When the workflow completes, it can optionally send an email to the address specified above in the ``params`` section.
For this to work, the following parameters must be changed to match the settings of your email server. You may need to contact your IT department to obtain the appropriate settings.

The example configuration file includes this ``mail`` section:

.. code-block:: groovy

    mail {
        from = 'address@host.com'
        smtp.host = 'smtp.host.com'
        smtp.port = 587
        smtp.user = 'smpt_user'
        smtp.password = 'smtp_password'
        smtp.auth = true
        smtp.starttls.enable = true
        smtp.starttls.required = false
        mail.smtp.ssl.protocols = 'TLSv1.2'
    }

Below is a description of each parameter:

.. list-table:: Parameters for the ``profiles/standard`` section
   :widths: 5 20 75
   :header-rows: 1

   * - Req?
     - Parameter Name
     - Description
   * - ✓
     - ``from``
     - The email address **from** which the email should be sent.
   * - ✓
     - ``smtp.host``
     - The internet address (host name or ip address) of the email SMTP server.
   * - ✓
     - ``smtp.port``
     - The port on the host to connect to. Most likely will be ``587``.
   * -
     - ``smtp.user``
     - If authentication is required, this is the username.
   * -
     - ``smtp.password``
     - If authentication is required, this is the password.
   * - ✓
     - ``smtp.auth``
     - Whether or not (true or false) authentication is required.
   * - ✓
     - ``smtp.starttls.enable``
     - Whether or not to enable TLS support.
   * - ✓
     - ``smtp.starttls.required``
     - Whether or not TLS is required.
   * - ✓
     - ``smtp.ssl.protocols``
     - SSL protocol to use for sending SMTP messages.
