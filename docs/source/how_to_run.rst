===================================
How to Run the Workflow
===================================
Follow these instructions to run the Nextflow DIA workflow from your system.
Note that your system must remain on for the duration of the running of the
workflow. Even though the steps may be running on AWS Batch, your system still
orchestrates the running of the steps.

.. important::

    You must set up your system to run Nextflow first. Please see
    :doc:`how_to_install` for more information.


Run the Workflow
===========================
Follow these steps to run a workflow:

1. Create a directory that will be the “home” directory for this search. Example commands:

    .. code
        cd
        mkdir my-nextflow-run
        cd my-nextflow-run

    This will create a directory named ``my-nextflow-run`` in your home directory and move into that directory.

2. Copy in or create a pipeline.config file. A template can be found at: https://raw.githubusercontent.com/mriffle/nf-teirex-dia/main/resources/pipeline.config Example command:

    .. code
        wget https://raw.githubusercontent.com/mriffle/nf-teirex-dia/main/resources/pipeline.config

    You may edit this config file in two ways:
    
    Command Line:
    ^^^^^^^^^^^^^
    Edit this file using:

    .. code
        nano pipeline.config

    Use the commands displayed in the bottom of the window to save the file and close the editor when you are done. They will be ``Control-O`` and ``<Enter>`` to save and ``Control-X`` to exit.

    GUI Editor in your Operating System:
    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    If you are using MacOS or Linux, you can directly edit ``~/my-nextflow-run/pipeline.config`` using your favorite GUI editor. If you are on Windows, the file is a little
    tricker to find. In your file open dialogue, type in ``\\wsl$\`` and hit enter. This should reveal a ``Ubuntu-22.04`` directory (or something close to it). Go into that and double click on ``home``, then double
    click on your username, then ``my-nextflow-run``. The ``pipeline.config`` file should be present and you can edit it like a normal file.
    




3. Run the latest version of the workflow using your executor of choice:

    - Get latest version:
    
    .. code
        nextflow pull -r main mriffle/nf-teirex-dia

    - Run the workflow:

        AWS Batch:
        nextflow run -resume -r main -profile aws mriffle/nf-teirex-dia -bucket-dir s3://bucket/dir -c pipeline.config
        Note: This will run your workflow on AWS Batch.

        Local System:
        Run: nextflow run -resume -r main mriffle/nf-teirex-dia -c pipeline.config
        Note: This will run your workflow on your local computer. Do not run multiple workflows at once this way as they will run at the same time.



How to retrieve results:
Results are in the “results” directory of the directory in which you ran Nextflow.
