
process CALCULATE_MD5 {
    label 'process_low'
    container params.images.ubuntu

    input:
        path(file_to_check)

    output:
        path('hash.txt')

    script:
        """
        md5sum ${file_to_check} > 'hash.txt'
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
