def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /usr/local/bin/encyclopedia.jar"
}

process ENCYCLOPEDIA_SEARCH_FILE {
    publishDir "${params.result_dir}/encyclopedia/search-file", failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container 'quay.io/protio/encyclopedia:2.12.30'

    input:
        path mzml_file
        path fasta
        path spectra_library_file

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${mzml_file}.elib", emit: elib)
        path("${mzml_file.baseName}.dia",  emit: dia)
        path("${mzml_file}.features.txt", emit: features_gzip)
        path("${mzml_file}.encyclopedia.txt", emit: results_targets)
        path("${mzml_file}.encyclopedia.decoy.txt", emit: results_decoys)
        

    script:
    // todo: research maccoss lab defaults from images in lab manual 
    """
    ${exec_java_command(task.memory)} \\
        -numberOfThreadsUsed ${task.cpus} \\
        -i ${mzml_file} \\
        -f ${fasta} \\
        -l ${spectra_library_file} \\
        ${params.encyclopedia.args} \\
        1>"encyclopedia-${mzml_file.baseName}.stdout" 2>"encyclopedia-${mzml_file.baseName}.stderr"
    """
}

process ENCYCLOPEDIA_CREATE_ELIB {
    publishDir "${params.result_dir}/encyclopedia/create-elib", failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container 'quay.io/protio/encyclopedia:2.12.30'

    input:
        path mzml_file
        path fasta
        path dlib

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${mzml_file.baseName}.elib", emit: elib)
        path("${mzml_file.baseName}.dia",  emit: dia)
        path("${mzml_file.baseName}.features.txt.gz", emit: features_gzip)
        path("${mzml_file.baseName}.encyclopedia.txt", emit: results_targets)
        path("${mzml_file.baseName}.encyclopedia.decoy.txt", emit: results_decoys)
        

    script:
    // todo: research maccoss lab defaults from images in lab manual 
    """
    ${exec_java_command(task.memory)} \\
        -numberOfThreadsUsed ${task.cpus} \\
        -i ${mzml_file.baseName} \\
        -f ${fasta} \\
        -l ${dlib} \\
        ${params.encyclopedia.args} \\
        1>"encyclopedia-${mzml_file.baseName}.stdout" 2>"encyclopedia-${mzml_file.baseName}.stderr"
    """
}
