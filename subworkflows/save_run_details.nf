
process WRITE_VERSION_INFO {
    label 'process_low_constant'
    executor 'local'
    publishDir "${params.result_dir}", failOnError: true, mode: 'copy'

    input:
        val workflow_var_names
        val workflow_values

    output:
        path('nextflow_run_details.txt'), emit: run_details

    script:
        """
        workflow_var_names=( '${workflow_var_names.join("' '")}' )
        workflow_values=( '${workflow_values.join("' '")}' )

        for i in \${!workflow_var_names[@]} ; do
            if [ \$i -eq 0 ] ; then
                echo "\${workflow_var_names[\$i]}: \${workflow_values[\$i]}" > 'nextflow_run_details.txt'
            else
                echo "\${workflow_var_names[\$i]}: \${workflow_values[\$i]}" >> 'nextflow_run_details.txt'
            fi
        done
        """
}

workflow save_run_details {

    take:
        input_files
        version_files

    main:

        // Read version txt files and create a channel of variable name, value pairs
        version_vars = version_files
            .map{ program ->
                program.collect{ it ->
                    def elems = it.split('=').collect{ str ->
                        str.strip().replaceAll(/^['"]|['"]$/, '')
                    }
                    [elems[0], elems[1]]
                }
            }

        // Create channel of workflow run metadata
        workflow_vars = Channel.fromList([["Nextflow run at", workflow.start],
                                          ["Nextflow version", nextflow.version],
                                          ["Workflow git address", "${workflow.repository}"],
                                          ["Workflow git revision (branch)", "${workflow.revision}"],
                                          ["Workflow git commit hash", "${workflow.commitId}"],
                                          ["Run session ID", workflow.sessionId],
                                          ["Command line", workflow.commandLine]])

        // Create channel of docker image names and paths
        docker_images = Channel.fromList(params.images.collect{k, v -> ["${k} docker image", v]})

        all_vars = workflow_vars
            .concat(
                input_files.flatten().collate(2),
                version_vars.flatten().collate(2),
                docker_images
            )

        var_names = all_vars.map{ it -> it[0] }
        var_values = all_vars.map{ it -> it[1] }

        WRITE_VERSION_INFO(var_names.collect(), var_values.collect())

    emit:
        run_details = WRITE_VERSION_INFO.out.run_details
}

