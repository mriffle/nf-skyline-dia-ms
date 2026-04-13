def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /opt/carafe/carafe-2.0.0/carafe-2.0.0.jar"
}

process CARAFE {
    publishDir "${params.result_dir}/carafe", failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container params.images.carafe

    input:
        path mzml_files
        path fasta_file
        path peptide_results_file
        val carafe_params
        val include_phosphorylation
        val include_oxidized_methionine
        val max_mod_option
        val output_format

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("carafe_spectral_library.tsv"), emit: speclib_tsv
        path("carafe_version.txt"), emit: version
        path("parameter.txt"), emit: carafe_parameter_file

    script:

        apptainer_cmds = ''
        // if (workflow.containerEngine == 'singularity' || workflow.containerEngine == 'apptainer') {
        //     // Running with Apptainer/Singularity
        //     apptainer_cmds = """
        //         source /opt/conda/etc/profile.d/conda.sh
        //         conda activate carafe
        //     """
        // }

        lf_type_param = output_format == 'diann' ? 'diann' : 'encyclopedia'

        mod_param = ''
        if(include_phosphorylation && include_oxidized_methionine) {
            mod_param = "-varMod 2,7,8,9 -mode phosphorylation ${max_mod_option}"
        } else if(include_phosphorylation) {
            mod_param = "-varMod 7,8,9 -mode phosphorylation ${max_mod_option}"
        } else if(include_oxidized_methionine) {
            mod_param = "-varMod 2 -mode general ${max_mod_option}"
        } else {
            mod_param = '-mode general'
        }

        """
        ${apptainer_cmds}

        export HOME=/tmp

        echo "\${JAVA_TOOL_OPTIONS:-<not set>}"
        python -c 'import sys; print(sys.executable)'
        java -XshowSettings:properties -version 2>&1 | grep 'user.home'
        ls -l /opt/carafe-home/.carafe/.venv/bin/python3
        /opt/carafe-home/.carafe/.venv/bin/python3 -c 'import torch, alphabase; print("ok")'

        ${exec_java_command(task.memory)} \\
            -ms "." \\
            -db "${fasta_file}" \\
            -i "${peptide_results_file}" \\
            -se "DIA-NN" \\
            -lf_type ${lf_type_param} \\
            -device cpu \\
            ${mod_param} \\
            ${carafe_params} \\
        > >(tee "carafe.stdout") 2> >(tee "carafe.stderr" >&2)

        # move SkylineAI_spectral_library.tsv if it exists (legacy compatibility)
        [ -e SkylineAI_spectral_library.tsv ] && mv -v SkylineAI_spectral_library.tsv carafe_spectral_library.tsv

        echo "carafe_version=\$CARAFE_VERSION" > carafe_version.txt
        """

    stub:
        """
        echo "carafe_version=\$CARAFE_VERSION" > carafe_version.txt
        touch carafe_spectral_library.tsv
        touch stub.stderr stub.stdout
        touch parameter.txt
        """
}
