===================================
Using a Custom DIA-NN Version
===================================
This workflow includes DIA-NN version 1.8.1, which is the latest version that may be hosted
in a public cloud container registry due to licensing restrictions. However, **newer versions of DIA-NN
can be used** by building a Docker image on the system where you will run the workflow.

A build script is provided that automates this process. It downloads the necessary files from
this project's GitHub repository and builds the Docker image for you.

.. note::

    These instructions only support **DIA-NN version 2.x** releases.

.. important::

    All commands on this page are typed in the **command line** (also called a terminal). If you
    are on Windows, this means the Ubuntu terminal in WSL2. See :doc:`how_to_install` for how to
    open a command line on your system.


Prerequisites
=============
Before you begin, ensure the following are installed and working on your system:

- **Docker**: Required for building and running container images.
- **Nextflow**: Required for running the workflow.
- **wget**: Used by the build script to download files. Usually pre-installed on Linux.

If you have not yet installed these, see :doc:`how_to_install` for instructions.

You can verify Docker is working by running:

.. code-block:: bash

    docker run hello-world

If you see a "Hello from Docker!" message, Docker is working correctly.


Step 1: Download the Build Script
==================================

.. code-block:: bash

    wget https://raw.githubusercontent.com/mriffle/nf-skyline-dia-ms/main/resources/diann-docker/build_diann_docker.sh


Step 2: Run the Build Script
=============================
Run the script with the DIA-NN version number you want to use. You can find available
versions at https://github.com/vdemichev/DiaNN/releases.

The version number must match the release exactly. Note that the first 2.x release is
numbered ``2.0``, not ``2.0.0``. If you give a version that does not exist, the script
will tell you so before it starts building.

For example, to build DIA-NN version 2.3.2:

.. code-block:: bash

    bash build_diann_docker.sh 2.3.2

The script will download the necessary files, build the Docker image, and print instructions
when it is finished. This may take a few minutes.

.. note::

    If you see an error that the Docker image already exists, you have already built this version.
    If you want to rebuild it, run the command shown in the error message to remove the existing
    image first.

To see all available options, run:

.. code-block:: bash

    bash build_diann_docker.sh -h


Step 3: Configure the Workflow
==============================
After the script completes, it will display the exact line to add to your ``pipeline.config``
file. Open your ``pipeline.config`` (see :doc:`how_to_run` for how to find and edit this file)
and add the line to the ``params`` section. For example, if you built version 2.3.2:

.. code-block:: groovy

    params {
        images.diann = 'diann:2.3.2'

        // ... your other parameters ...
    }

After saving your ``pipeline.config``, run the workflow as you normally would (see :doc:`how_to_run`).
The workflow will automatically use your custom DIA-NN version for the DIA-NN search step.

No other parameter changes are needed. DIA-NN 2.x names its output files differently than 1.8.1,
and the workflow detects and handles both naming conventions automatically:

.. list-table::
   :header-rows: 1

   * - File in the ``diann`` results directory
     - DIA-NN 1.8.1
     - DIA-NN 2.x
   * - Precursor report
     - ``quant.tsv``
     - ``quant.parquet``
   * - Spectral library used to build the Skyline library
     - ``quant.tsv.speclib``
     - ``quant.parquet.skyline.speclib``

If a chromatogram library search is also run, its ``subset_library`` files follow the same pattern.
Every other file, including the ``.blib`` library that is imported into Skyline, has the same
name with either version.


Using a Custom Image on AWS Batch
==================================

.. warning::

    An image built with the script above exists **only on the computer where you built it**. It
    works when the steps of the workflow run on that computer (for example, the ``standard``
    profile or a Slurm executor), but it is **not** available to AWS Batch.

If you run the workflow with ``-profile aws`` (see :doc:`set_up_aws`), AWS Batch pulls container
images from a registry rather than from your local Docker installation. To use a custom DIA-NN
version on AWS Batch, you must first push the image you built to a container registry that your
AWS Batch compute environment can pull from, such as `Amazon ECR
<https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html>`_. Because of
the DIA-NN licensing restrictions described above, this registry must be **private**.

Once the image has been pushed, set ``images.diann`` to the full registry URI of the pushed image
instead of the local ``diann:<version>`` tag. For example:

.. code-block:: groovy

    params {
        images.diann = '123456789012.dkr.ecr.us-west-2.amazonaws.com/diann:2.3.2'

        // ... your other parameters ...
    }


Verifying the Version
=====================
After the workflow completes, you can confirm which version of DIA-NN was used by checking
the ``diann_version.txt`` file in the ``diann`` subdirectory of the results directory. See
:doc:`results` for more information about output files.
