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
     - That path to the spectral library to use. May be a ``dlib``, ``elib``, ``blib``, ``speclib`` (DIA-NN), ``tsv`` (DIA-NN), or other formats supported by EncyclopeDIA or DIA-NN. This parameter is required for EncyclopeDIA. If omitted when using DIA-NN, DIA-NN will be run in library-free mode. This parameter is ignored when running Cascadia.
   * - 
     - ``fasta``
     - The path to the background FASTA file to use. This parameter is required, except when running Cascadia.
   * - ✓
     - ``quant_spectra_dir``
     - The path to the directory containing the raw data to be quantified. If using narrow window DIA and GPF to generated a chromatogram library this is the location of the wide-window data to be searched using the chromatogram library.
   * -
     - ``quant_spectra_glob``
     - Which files in this directory to use. Default: ``*.raw``
   * -
     - ``chromatogram_library_spectra_dir``
     - If you are creating a chromatogram library using GPF and narrow window DIA, this is the path to the directory containing the narrow-window raw data.
   * -
     - ``chromatogram_library_spectra_glob``
     - Which files in this directory to use. Default: ``*.raw``
   * -
     - ``search_engine``
     - Must be set to either ``'encyclopedia'``, ``'diann'``, or ``'cascadia'``. If set to ``'diann'`` or ``'cascadia'``, ``chromatogram_library_spectra_dir``, ``chromatogram_library_spectra_glob``, and EncyclopeDIA-specific parameters will be ignored. Default: ``'encyclopedia'``.
   * -
     - ``pdc.study_id``
     - When this option is set, raw files and metadata will be downloaded from the PDC. Default: ``null``.
   * -
     - ``pdc.gene_level_data``
     - A ``tsv`` file mapping gene names to NCIB gene IDs and gene metadata. Required for PDC gene reports. Default: ``null``.
   * -
     - ``pdc.n_raw_files``
     - If this option is set, only ``n`` raw files are downloaded. This is useful for testing but otherwise should be ``null``.
   * -
     - ``pdc.client_args``
     - Additional command line arguments passed to ``PDC_client``. Default is ``null``.
   * -
     - ``skyline.skip``
     - If set to ``true``, will skip the creation of a Skyline document. Default: ``false``.
   * -
     - ``skyline.document_name``
     - The base of the file name of the generated Skyline document. If set to ``'human_dia'``, the output file name would be ``human_dia.sky.zip``. Note: If importing into PanoramaWeb, this is also the name that appears in the list of imported Skyline documents on the project page. Default: ``final``.
   * -
     - ``msconvert.do_demultiplex``
     - If starting with raw files, this is the value used by ``msconvert`` for the ``do_demultiplex`` parameter. Default: ``true``.
   * -
     - ``msconvert.do_simasspectra``
     - If starting with raw files, this is the value used by ``msconvert`` for the ``do_simasspectra`` parameter. Default: ``true``.
   * -
     - ``msconvert.mz_shift_ppm``
     - If starting with raw files, ``msconvert`` will shift all mz values by ``n`` ppm when converting to ``mzML``. If ``null`` the mz values are not shifted. Default: ``null``.
   * -
     - ``encyclopedia.chromatogram.params``
     - If you are generating a chromatogram library for quantification, this is the command line options passed to EncyclopeDIA during the chromatogram generation step. Default: ``'-enableAdvancedOptions -v2scoring'`` If you do not wish to pass any options to EncyclopeDIA, this must be set to ``''``.
   * -
     - ``encyclopedia.quant.params``
     - The command line options passed to EncyclopeDIA during the quantification step. Default: ``'-enableAdvancedOptions -v2scoring'`` If you do not wish to pass any options to EncyclopeDIA, this must be set to ``''``.
   * -
     - ``encyclopedia.save_output``
     - EncyclopeDIA generates many intermediate files that are subsequently processed by the workflow to generate the final results. These intermediate files may be large. If this is set to ``'true'``, these intermediate files will be saved locally in your ``results`` directory. Default: ``'false'``.
   * -
     - ``diann.params``
     - The parameters passed to DIA-NN when it is run. Default: ``'--unimod4 --qvalue 0.01 --cut \'K*,R*,!*P\' --reanalyse --smart-profiling'``
   * -
     - ``cascadia.use_gpu``
     - If set to ``true``, Cascadia will attempt to use the GPU(s) installed on the system where it is running. Do not set to true unless a GPU is available, otherwise an error will be gernated. Default: ``false``.
   * -
     - ``panorama.upload``
     - Whether or not to upload results to PanoramaWeb Default: ``false``.
   * -
     - ``panorama.upload_url``
     - The WebDAV URL of a directory in PanoramaWeb to which to upload the results. Note that ``panorama.upload`` must be set to ``true`` to upload results.
   * -
     - ``panorama.import_skyline``
     - If set to ``true``, the generated Skyline document will be imported into PanoramaWeb's relational database for inline visualization. The import will appear in the parent folder for the ``panorama.upload_url`` parameter, and will have the named used for the ``skyline_document_name`` parameter. Default: ``false``. Note: ``panorama_upload`` must be set to ``true`` and ``skip_skyline`` must be set to ``false`` to use this feature.
   * -
     - ``skyline.skyr_file``
     - Path(s) (local file system or Panorama WebDAV) to a ``.skyr`` file, which is a Skyline report template. Any reports specified in the ``.skyr`` file will be run automatically as the last step of the workflow and the results saved in your ``results`` directory and (if requested) uploaded to Panorama. The report template(s) can be a single string, or for multiple ``.skyr`` files can be given as a list of strings.
       For example: ``'/path/to/report.skyr'`` for a single file, or
       ``['/path/to/report_1.skyr', '/path/to/report_2.skyr']`` for multiple files.
   * -
     - ``skyline.template_file``
     - The Skyline template file used to generate the final Skyline file. By default a
       pre-made Skyline template file suitable for EncyclopeDIA or DIA-NN will be used. Specify a file
       location here to use your own template. Note: The filenames in the .zip file must match
       the name of the zip file, itself. E.g., ``my-skyline-template.zip`` must contain ``my-skyline-template.sky``.
   * -
     - ``skyline.protein_parsimony``
     - If ``true``, protein parsimony is performed in Skyline. If ``false`` the protein assignments given by the search engine are used as protein groups. Default is ``false``.
   * -
     - ``skyline.fasta``
     - The fasta file to use as a background proteome in Skyline. If ``null`` the same fasta file (``params.fasta``) used for the DIA search is used. Default is ``null``.
   * -
     - ``skyline.group_by_gene``
     - If ``true``, when protein parsimony is performed in Skyline protein groups are formed by gene instead of by protein. Default is ``false``.
   * -
     - ``skyline.minimize``
     - If ``true``, the size of the final Skyline document is minimized. Chromatograms for isotopic peaks that are not in the document are removed from the ``skyd`` file and a minimal spectral library is generated by removing spectra that are not in the document. Default is ``false``.
   * -
     - ``skyline.use_hardlinks``
     - On systems that allow it, setting this to ``true`` allows the use of cached Skyline workflow steps and may improve performance on subsequent runs. Note: some systems do not allow this, which will result in an error. Default: ``false``.
   * -
     - ``replicate_metadata``
     - Metadata annotations for each ``raw`` or ``mzML`` file. Can be in ``tsv`` or ``csv`` format. See the :ref:`replicate_metadata` section for details of how the file should be formatted. If a metadata file is specified it will be used to add annotations to the final Skyline document and can be used to color PCA plots in the QC report by specifying the ``qc_report.color_vars`` parameter. If this parameter is set to ``null`` the skyline document annotation step is skipped.
   * -
     - ``qc_report.skip``
     - If set to ``true``, will skip the creation of a the QC report. Default: ``true``.
   * -
     - ``qc_report.normalization_method``
     - Normalization method to use for plots in QC report. Available options are ``DirectLFQ`` and ``median``.
       Default is ``median``
   * -
     - ``qc_report.standard_proteins``
     - List of protein names in Skyline document to plot retention times for.

       For example: ``['iRT', 'sp|P00924|ENO1_YEAST']``

       If ``null``, the standard protein retention time plot is skipped. Default is ``null``
   * -
     - ``qc_report.color_vars``
     - List of metadata variables to color PCA plots by.

       For example: ``['sample_type', 'strain']``

       If ``null``, only a single PCA plot colored by file acquisition order is generated. Default is ``null``
   * -
     - ``qc_report.export_tables``
     - Export tsv files containing normalized precursor and protein quantities? Default is ``false``
   * -
     - ``email``
     - The email address to which a notification should be sent upon workflow completion. If no email is specified, no email will be sent. To send email, you must configure mail server settings (see below).


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
