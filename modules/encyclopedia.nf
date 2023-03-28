def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /usr/local/bin/encyclopedia.jar"
}

process ENCYCLOPEDIA_CREATE_ELIB {
    publishDir "${params.result_dir}/encyclopedia", failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container 'quay.io/protio/encyclopedia:2.12.30'

    input:
        path mzml_file
        path fasta
        path dlib



    output:
        path("${pin.baseName}.filtered.pin"), emit: filtered_pin
        path("*.stderr"), emit: stderr

    script:
    // todo: set number of threads equal to task cores
    // todo: research maccoss lab defaults from images in lab manual 
    """
    ${exec_java_command(task.memory)} \\
        -i ${mzml_file} \\
        -f ${fasta} \\
        -l ${dlib} \\
        ${params.encyclopedia.args} \\
        ${params.encyclopedia.local.args} \\
    """

    stub:
    """
    touch "${pin.baseName}.filtered.pin"
    """
}
