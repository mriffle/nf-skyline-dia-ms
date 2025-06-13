
process CALCULATE_MD5 {
    cpus   1
    /* 8 GB or 1.5 times the file size, whichever is larger
     md5sum does not load the eitire file at once,
     but the aws s3 copy process will run out or memory for large files */
    memory { Math.max(8.0, (file_to_check.size() / (1024 ** 3)) * 1.5).GB }
    time   { 15.m * task.attempt }
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
