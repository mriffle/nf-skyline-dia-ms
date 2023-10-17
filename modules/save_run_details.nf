// create and return a text file that contains
// details about this nextflow workflow run

process SAVE_RUN_DETAILS {
    label 'process_low_constant'
    publishDir "${params.result_dir}", failOnError: true, mode: 'copy'
    container "${workflow.profile == 'aws' ? 'public.ecr.aws/docker/library/ubuntu:22.04' : 'ubuntu:22.04'}"

    output:
        path("nextflow_run_details.txt"), emit: run_details

    script:
        """

        echo "Nextflow run at: ${workflow.start}" > nextflow_run_details.txt
        echo "Nextflow version: ${nextflow.version}" >> nextflow_run_details.txt
        echo "Workflow git address: ${workflow.repository}" >> nextflow_run_details.txt
        echo "Workflow git revision (branch): ${workflow.revision}" >> nextflow_run_details.txt
        echo "Workflow git commit hash: ${workflow.commitId}" >> nextflow_run_details.txt
        echo "Run session ID: ${workflow.sessionId}" >> nextflow_run_details.txt
        echo "Command line: ${workflow.commandLine}" >> nextflow_run_details.txt

        echo "Done!" # Needed for proper exit
        """
}
