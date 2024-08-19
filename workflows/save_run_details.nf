
process WRITE_VERSION_INFO {
    label 'process_low_constant'
    publishDir "${params.result_dir}", failOnError: true, mode: 'copy'
    container params.images.ubuntu

    input:
        val workflow_var_names
        val workflow_values
        val version_file_name

    output:
        path(version_file_name), emit: run_details

    shell:
        '''
        workflow_var_names=( '!{workflow_var_names.join("' '")}' )
        workflow_values=( '!{workflow_values.join("' '")}' )

        for i in ${!workflow_var_names[@]} ; do
            if [ $i -eq 0 ] ; then
                echo "${workflow_var_names[$i]}: ${workflow_values[$i]}" > '!{version_file_name}'
            else
                echo "${workflow_var_names[$i]}: ${workflow_values[$i]}" >> '!{version_file_name}'
            fi
        done
        '''
}

workflow save_run_details {

    take:
        input_files
        version_files

    emit:
        run_details

    main:

        // split program version variable names and value
        version_vars = version_files.map{
            program -> program.collect{ it ->
                elems = it.split('=') 
                [elems[0].strip(), elems[1].strip()]
            }
        }

        version_vars.view()

        workflow_vars = Channel.fromList([["Nextflow run at", workflow.start],
                                          ["Nextflow version", nextflow.version],
                                          ["Workflow git address", "${workflow.repository}"],
                                          ["Workflow git revision (branch)", "${workflow.revision}"],
                                          ["Workflow git commit hash", "${workflow.commitId}"],
                                          ["Run session ID", workflow.sessionId],
                                          ["Command line", workflow.commandLine]])

        all_vars = workflow_vars.concat(version_vars)

        var_names = all_vars.map{ it -> it[0] }
        var_values = all_vars.map{ it -> it[1] }

        WRITE_VERSION_INFO(var_names.collect(), var_values.collect(),
                           'nextflow_run_details.txt')

        run_details = WRITE_VERSION_INFO.out.run_details
}

