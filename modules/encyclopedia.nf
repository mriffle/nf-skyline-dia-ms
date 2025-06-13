def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /usr/local/bin/encyclopedia.jar"
}

process ENCYCLOPEDIA_SEARCH_FILE {
    publishDir params.output_directories.encyclopedia.search_file, pattern: "*.stderr", failOnError: true, mode: 'copy'
    publishDir params.output_directories.encyclopedia.search_file, pattern: "*.stdout", failOnError: true, mode: 'copy'
    publishDir params.output_directories.encyclopedia.search_file, pattern: "*.elib", failOnError: true, mode: 'copy', enabled: params.encyclopedia.save_output
    publishDir params.output_directories.encyclopedia.search_file, pattern: "*.features.txt", failOnError: true, mode: 'copy', enabled: params.encyclopedia.save_output
    publishDir params.output_directories.encyclopedia.search_file, pattern: "*.encyclopedia.txt", failOnError: true, mode: 'copy', enabled: params.encyclopedia.save_output
    publishDir params.output_directories.encyclopedia.search_file, pattern: "*.encyclopedia.decoy.txt", failOnError: true, mode: 'copy', enabled: params.encyclopedia.save_output
    cpus   8
    memory { 16.GB * task.attempt }
    time   { 4.h  * task.attempt }
    label 'ENCYCLOPEDIA_SEARCH_FILE'
    container params.images.encyclopedia

    input:
        path mzml_file
        path fasta
        path spectra_library_file
        val encyclopedia_params

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${mzml_file}.elib"), emit: elib
        path("${mzml_file.baseName}.dia"),  emit: dia
        path("${mzml_file}.features.txt"), emit: features
        path("${mzml_file}.encyclopedia.txt"), emit: results_targets
        path("${mzml_file}.encyclopedia.decoy.txt"), emit: results_decoys
        path("output_file_stats.txt"), emit: output_file_stats


    script:
    """
    ${exec_java_command(task.memory)} \\
        -numberOfThreadsUsed ${task.cpus} \\
        -i ${mzml_file} \\
        -f ${fasta} \\
        -l ${spectra_library_file} \\
        -percolatorVersion /usr/local/bin/percolator \\
        ${encyclopedia_params} \\
        > >(tee "encyclopedia-${mzml_file.baseName}.stdout") 2> >(tee "encyclopedia-${mzml_file.baseName}.stderr" >&2)

    md5sum *.elib *.features.txt *.encyclopedia.txt *.encyclopedia.decoy.txt *.mzML | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
    stat -L --printf='%n\\t%s\\n' *.elib *.features.txt *.encyclopedia.txt *.encyclopedia.decoy.txt *.mzML | sort > sizes.txt
    join -t\$'\\t' hashes.txt sizes.txt > output_file_stats.txt
    """

    stub:
    """
    touch stub.stderr stub.stdout
    touch ${mzml_file}.elib
    touch "${mzml_file.baseName}.dia"
    touch ${mzml_file}.features.txt
    touch ${mzml_file}.encyclopedia.txt
    touch ${mzml_file}.encyclopedia.decoy.txt

    md5sum *.elib *.features.txt *.encyclopedia.txt *.encyclopedia.decoy.txt *.mzML | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
    stat -L --printf='%n\\t%s\\n' *.elib *.features.txt *.encyclopedia.txt *.encyclopedia.decoy.txt *.mzML | sort > sizes.txt
    join -t\$'\\t' hashes.txt sizes.txt > output_file_stats.txt
    """
}

process ENCYCLOPEDIA_CREATE_ELIB {
    publishDir params.output_directories.encyclopedia.create_elib, failOnError: true, mode: 'copy'
    cpus  32
    memory { Math.max(32, search_elib_files.size() * 4).GB }
    time   { 24.h  * task.attempt }
    label 'ENCYCLOPEDIA_CREATE_ELIB'
    container params.images.encyclopedia

    input:
        path search_elib_files
        path search_dia_files
        path search_feature_files
        path search_encyclopedia_targets
        path search_encyclopedia_decoys
        path fasta
        path spectra_library_file
        val align
        val outputFilePrefix
        val encyclopedia_params

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${outputFilePrefix}-combined-results.elib"), emit: elib
        path("${outputFilePrefix}-combined-results.elib.peptides.txt"), emit: peptide_quant, optional: true
        path("${outputFilePrefix}-combined-results.elib.proteins.txt"), emit: protein_quant, optional: true
        path("encyclopedia_version.txt"), emit: version

    script:
    """
    find * -name '*\\.mzML\\.*' -exec bash -c 'mv \$0 \${0/\\.mzML/\\.dia}' {} \\;

    ${exec_java_command(task.memory)} \\
        -numberOfThreadsUsed ${task.cpus} \\
        -libexport \\
        -o '${outputFilePrefix}-combined-results.elib' \\
        -i ./ \\
        -a ${align} \\
        -f ${fasta} \\
        -l ${spectra_library_file} \\
        -percolatorVersion /usr/local/bin/percolator \\
        ${encyclopedia_params} \\
        > >(tee "${outputFilePrefix}.stdout") 2> >(tee "${outputFilePrefix}.stderr" >&2)

    # get EncyclopeDIA version info
    ${exec_java_command(task.memory)} --version > version.txt || echo "encyclopedia_version_exit=\$?"
    echo "encyclopedia_version=\$(cat version.txt| awk '{print \$4}')" > encyclopedia_version.txt
    """

    stub:
    """
    touch stub.stderr stub.stdout
    touch "${outputFilePrefix}-combined-results.elib"
    touch "${outputFilePrefix}-combined-results.elib.peptides.txt"
    touch "${outputFilePrefix}-combined-results.elib.proteins.txt"

    # get EncyclopeDIA version info
    ${exec_java_command(task.memory)} --version > version.txt || echo "encyclopedia_version_exit=\$?"
    echo "encyclopedia_version=\$(cat version.txt| awk '{print \$4}')" > encyclopedia_version.txt
    """
}

process ENCYCLOPEDIA_BLIB_TO_DLIB {
    publishDir params.output_directories.encyclopedia.convert_blib, failOnError: true, mode: 'copy'
    label 'process_medium'
    label 'process_high_memory'
    container params.images.encyclopedia

    input:
        path fasta
        path blib

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${blib.baseName}.dlib"), emit: dlib

    script:
    """
    ${exec_java_command(task.memory)} \\
        -numberOfThreadsUsed ${task.cpus} \\
        -convert \\
        -blibToLib \\
        -o "${blib.baseName}.dlib" \\
        -i "${blib}" \\
        -f "${fasta}" \\
        > >(tee "encyclopedia-convert-blib.stdout") 2> >(tee "encyclopedia-convert-blib.stderr" >&2)
    """

    stub:
    """
    touch stub.stderr stub.stdout
    touch "${blib.baseName}.dlib"
    """
}

process ENCYCLOPEDIA_DLIB_TO_TSV {
    publishDir params.output_directories.encyclopedia.convert_blib, failOnError: true, mode: 'copy'
    label 'process_medium'
    label 'process_high_memory'
    container params.images.encyclopedia3_mriffle

    input:
        path dlib

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${dlib.baseName}.tsv"), emit: tsv

    script:
    """
    ${exec_java_command(task.memory)} \\
        -numberOfThreadsUsed ${task.cpus} \\
        -convert \\
        -libraryToOpenswathTSV \\
        -o "${dlib.baseName}.tsv" \\
        -i "${dlib}" \\
        > >(tee "encyclopedia-convert-dlib.stdout") 2> >(tee "encyclopedia-convert-dlib.stderr" >&2)
    """

    stub:
    """
    touch stub.stderr stub.stdout
    touch "${dlib.baseName}.tsv"
    """
}
