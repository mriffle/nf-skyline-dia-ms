
process DIANN_BUILD_LIB {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    label 'process_high'
    container params.images.diann

    input:
        path fasta_file
        val lib_build_params

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${fasta_file.baseName}.predicted.speclib"), emit: speclib

    script:
        """
        diann --fasta ${fasta_file} \
            ${lib_build_params} \
            --predictor --gen-spec-lib --fasta-search --out-lib ${fasta_file.baseName}.speclib \
            > >(tee "predict_lib.stdout") 2> >(tee "predict_lib.stderr" >&2)
        """

    stub:
        """
        touch ${fasta_file.baseName}.predicted.speclib predict_lib_stub.stdout predict_lib_stub.stderr
        """
}

process DIANN_SEARCH {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container params.images.diann

    input:
        path ms_files
        path fasta_file
        path spectral_library
        val output_report_name
        val diann_params

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("*.parquet.skyline.speclib"), emit: speclib
        path("${output_report_name}.parquet"), emit: precursor_report
        path("*.quant"), emit: quant_files
        path("diann_version.txt"), emit: version
        path("output_file_stats.txt"), emit: output_file_stats

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
            --fasta ${fasta_file} \
            --lib ${spectral_library} \
            --out-lib ${output_report_name} \
            --out ${output_report_name} \
            ${diann_params} \
            > >(tee "diann.stdout") 2> >(tee "diann.stderr" >&2)

        head -n 2 diann.stdout | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "diann_version=%s\\n" > diann_version.txt

        md5sum '${ms_files.join('\' \'')}' ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet *.quant | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\\t%s\\n' '${ms_files.join('\' \'')}' ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet *.quant | sort > sizes.txt
        join -t\$'\t' hashes.txt sizes.txt > output_file_stats.txt
        """

    stub:
        """
        touch ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet stub.quant
        touch stub.stderr stub.stdout
        diann | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "diann_version=%s\\n" > diann_version.txt

        md5sum '${ms_files.join('\' \'')}' ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet *.quant | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\\t%s\\n' '${ms_files.join('\' \'')}' ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet *.quant | sort > sizes.txt
        join -t\$'\t' hashes.txt sizes.txt > output_file_stats.txt
        """
}

process DIANN_QUANT {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    label 'process_high'
    container params.images.diann

    input:
        path ms_file
        path fasta_file
        path spectral_library
        val diann_params

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("*.quant"), emit: quant_file

    script:
        """
        diann --f ${ms_file} \
              --fasta ${fasta_file} \
              --lib ${spectral_library} \
              --threads ${task.cpus} \
              ${diann_params} \
            > >(tee "${ms_file.baseName}.stdout") 2> >(tee "${ms_file.baseName}.stderr" >&2)
        """

    stub:
        """
        touch "${ms_file.baseName}.quant" "${ms_file.baseName}.stdout" "${ms_file.baseName}.stderr"
        """
}


process DIANN_MBR {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container params.images.diann

    input:
        path ms_files
        path quant_files
        path fasta_file
        path spectral_library
        val output_report_name
        val diann_params

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${output_report_name}.parquet.skyline.speclib"), emit: speclib
        path("${output_report_name}.parquet"), emit: precursor_report
        path("diann_version.txt"), emit: version
        path("output_file_stats.txt"), emit: output_file_stats

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
            --fasta ${fasta_file} \
            --lib ${spectral_library} \
            --use-quant \
            --out-lib ${output_report_name} \
            --out ${output_report_name} \
            ${diann_params} \
            > >(tee "diann.stdout") 2> >(tee "diann.stderr" >&2)

        head -n 2 diann.stdout | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "diann_version=%s\\n" > diann_version.txt

        md5sum '${ms_files.join('\' \'')}' ${output_report_name}.parquet ${output_report_name}.parquet.skyline.speclib *.quant | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\\t%s\\n' '${ms_files.join('\' \'')}' ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet *.quant | sort > sizes.txt
        join -t\$'\t' hashes.txt sizes.txt > output_file_stats.txt
        """

    stub:
        """
        touch ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet stub.quant
        touch stub.stderr stub.stdout
        diann | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "diann_version=%s\\n" > diann_version.txt

        md5sum '${ms_files.join('\' \'')}' ${output_report_name}.parquet ${output_report_name}.parquet.skyline.speclib *.quant | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\\t%s\\n' '${ms_files.join('\' \'')}' ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet *.quant | sort > sizes.txt
        join -t\$'\t' hashes.txt sizes.txt > output_file_stats.txt
        """
}

process BLIB_BUILD_LIBRARY {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    label 'process_medium'
    container params.images.proteowizard

    input:
        path speclib
        path precursor_report

    output:
        path('lib.blib'), emit: blib

    script:
        """
        wine BlibBuild "${speclib}" lib_redundant.blib
        wine BlibFilter -b 1 lib_redundant.blib lib.blib
        """

    stub:
        """
        touch lib.blib
        """
}
