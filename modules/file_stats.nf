
process CALCULATE_MD5 {
    label 'process_low'
    container params.images.ubuntu

    input:
        path(file_to_check)

    output:
        tuple val("${file_to_check.name}"), env("md5_sum")

    script:
        """
        md5_sum=\$( md5sum ${file_to_check} |awk '{print \$1}' )
        """
}

process WRITE_FILE_STATS {
    label 'process_low'
    executor 'local'
    publishDir "${params.result_dir}", failOnError: true, mode: 'copy'

    input:
        val file_stats

    output:
        path("file_checksums.tsv")

    script:
        data = file_stats.join('\\n')
        """
        text="${data}"

        echo -e 'file\\tpath\\tmd5_hash\\tsize' > file_checksums.tsv
        echo -e \$text >> file_checksums.tsv
        """
}
