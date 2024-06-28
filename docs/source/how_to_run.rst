===================================
How to Run the Workflow
===================================
Follow these instructions to run the Nextflow DIA workflow from your system.
Note that your system must remain on for the duration of the running of the
workflow. Even though the steps may be running on AWS Batch, your system still
orchestrates the running of the steps.

.. important::

    You must set up your system to run Nextflow first. Please see
    :doc:`how_to_install` for more information. All commands will be
    typed in the command line. See :doc:`how_to_install` for more
    information about how to get a command line.

Follow these steps to run a workflow:

1. Create a directory that will be the “home” directory for this search. Example commands:

    .. code-block:: bash

        cd
        mkdir my-nextflow-run
        cd my-nextflow-run

    This will create a directory named ``my-nextflow-run`` in your home directory and move into that directory.

2. Copy in or create a pipeline.config file. A template can be found at: https://raw.githubusercontent.com/mriffle/nf-skyline-dia-ms/main/resources/pipeline.config

    Example command:

    .. code-block:: bash

       wget https://raw.githubusercontent.com/mriffle/nf-skyline-dia-ms/main/resources/pipeline.config

    You may edit this config file in two ways:
        
    **Command Line**:

    .. code-block:: bash

        nano pipeline.config

    Use the commands displayed in the bottom of the window to save the file and close the editor when you are done. They will be ``Control-O`` and ``<Enter>`` to save and ``Control-X`` to exit.

    **GUI Editor in your Operating System:**

        *MacOS or Linux*: You can directly edit ``~/my-nextflow-run/pipeline.config`` using your favorite GUI editor.
        
        *Windows*: The file is a little tricky to find. In your file open dialogue, type in ``\\wsl$\`` and hit enter.
        This should reveal a ``Ubuntu-22.04`` directory (or something close to it). Go into that and double click on ``home``, then double
        click on your username, then ``my-nextflow-run``. The ``pipeline.config`` file should be present and you can edit it like a normal file.
    
    .. important::

        For a complete desciption of all parameters see 
        :doc:`workflow_parameters`.


3. Run the workflow.

   Nextflow workflows may be run with a variety of *executors*. Executors are what run the actual steps of the pipeline; that is, they are
   the systems on which steps like Encyclopedia and msconvert will be run. Examples of executors are your local computer, a computer cluster, or
   AWS Batch. The example below describes how to run the workflow using your local system or AWS Batch as the executor. 


   A good first step is to ensure you have the latest version of the workflow. Execute this command:
    
    .. code-block:: bash

        nextflow pull -r main mriffle/nf-skyline-dia-ms

   Then, to run the steps of the workflow on your **local computer**, execute this command:

    .. code-block:: bash

        nextflow run -resume -r main mriffle/nf-skyline-dia-ms -c pipeline.config
    
    .. note::

        It is important to only launch one workflow at a time if you are running on your local computer. Launching multiple
        workflows at once will result in multiple instances of the programs running at once. To run multiple workflows at
        once on your local system, you will need to implementing a queuing system such as **Slurm** and use the Slurm
        executor.

   Alternatively, to run the workflow using **AWS Batch**, execute a command similar to:

    .. code-block:: bash

        nextflow run -resume -r main -profile aws mriffle/nf-skyline-dia-ms -bucket-dir s3://bucket/dir -c pipeline.config

    .. important::

        You must set up a AWS Batch cluster before running on AWS Batch. See :doc:`set_up_aws` for more details about
        how to set up a AWS Batch cluster and the resulting parameters to set in your ``pipeline.config`` file.


4. Retrieve results.

   Your results will appear in the ``results`` sub directory of your current directory. See :doc:`results` for more
   information about the results that are generated.
