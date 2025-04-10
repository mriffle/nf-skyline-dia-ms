def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /opt/carafe/carafe-0.0.1/carafe-0.0.1.jar"
}

process CARAFE {
    publishDir "${params.result_dir}/carafe", failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container params.images.carafe

    input:
        path mzml_file
        path fasta_file
        path peptide_results_file
        val carafe_params
        val output_format

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("carafe_spectral_library.tsv"), emit: speclib_tsv
        path("carafe_version.txt"), emit: version
        path("parameter.txt"), emit: carafe_parameter_file

    script:

        apptainer_cmds = ''
        if (workflow.containerEngine == 'singularity' || workflow.containerEngine == 'apptainer') {
            // Running with Apptainer/Singularity
            apptainer_cmds = """
                source /opt/conda/etc/profile.d/conda.sh
                conda activate carafe
            """
        }

        lf_type_param = output_format == 'diann' ? 'diann' : 'encyclopedia'

        """
        ${apptainer_cmds}

        ${exec_java_command(task.memory)} \\
            -ms "${mzml_file}" \\
            -db "${fasta_file}" \\
            -i "${peptide_results_file}" \\
            -se "DIA-NN" \\
            -lf_type ${lf_type_param} \\
            -device cpu \\
            ${carafe_params} \\
        > >(tee "carafe.stdout") 2> >(tee "carafe.stderr" >&2)

        mv -v SkylineAI_spectral_library.tsv carafe_spectral_library.tsv

        grep "Version:" carafe.stdout | head -n 1 | awk '{print \$2}' | xargs printf "carafe_version=%s\n" > carafe_version.txt
        """

    stub:
        """
        touch carafe_spectral_library.tsv carafe_version.txt
        touch stub.stderr stub.stdout
        touch parameter.txt
        """
}