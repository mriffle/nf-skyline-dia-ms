process DIANN_SEARCH {
    publishDir "${params.result_dir}/diann", failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container "quay.io/protio/diann:1.8.1"
    
    input:
        path ms_files
        path fasta_file
        path spectral_library
        val diann_params
    
    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("report.tsv.speclib"), emit: speclib
        path("report.tsv"), emit: precursor_tsv
        path("*.quant"), emit: quant_files

    script:

        /* 
         * dia-nn will produce different results if the order of the input files is different
         * sort the files to ensure they are in the same order in every run
         */
        sorted_ms_files = ms_files.toList().sort { a, b -> a.toString() <=> b.toString() }

        ms_file_args = "--f '${sorted_ms_files.join('\' --f \'')}'"

        """
        diann ${ms_file_args} \
            --threads ${task.cpus} \
            --fasta "${fasta_file}" \
            --lib "${spectral_library}" \
            ${diann_params} \
            > >(tee "diann.stdout") 2> >(tee "diann.stderr" >&2)
        mv -v lib.tsv.speclib report.tsv.speclib
        """

    stub:
        """
        touch report.tsv.speclib report.tsv
        """
}

process DIANN_SEARCH_LIB_FREE {
    publishDir "${params.result_dir}/diann", failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container "quay.io/protio/diann:1.8.1"
    
    input:
        path ms_files
        path fasta_file
        val diann_params
    
    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("report.tsv.speclib"), emit: speclib
        path("report.tsv"), emit: precursor_tsv
        path("*.quant"), emit: quant_files

    script:

        /* 
         * dia-nn will produce different results if the order of the input files is different
         * sort the files to ensure they are in the same order in every run
         */
        sorted_ms_files = ms_files.toList().sort { a, b -> a.toString() <=> b.toString() }

        ms_file_args = "--f '${sorted_ms_files.join('\' --f \'')}'"

        """
        diann ${ms_file_args} \
            --threads ${task.cpus} \
            --fasta "${fasta_file}" \
            --fasta-search \
            --predictor \
            ${diann_params} \
            > >(tee "diann.stdout") 2> >(tee "diann.stderr" >&2)
        mv -v lib.tsv.speclib report.tsv.speclib
        """

    stub:
        """
        touch report.tsv.speclib report.tsv
        """
}


process BLIB_BUILD_LIBRARY {
    publishDir "${params.result_dir}/diann", failOnError: true, mode: 'copy'
    label 'process_medium'
    container 'quay.io/protio/bibliospec-linux:3.0'

    input:
        path speclib
        path precursor_tsv

    output:
        path('lib.blib'), emit: blib

    script:
        """
        BlibBuild "${speclib}" lib_redundant.blib
        BlibFilter lib_redundant.blib lib.blib
        """

    stub:
        """
        touch lib.blib
        """
}