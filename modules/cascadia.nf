process CASCADIA_SEARCH {
    publishDir params.output_directories.cascadia, failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container params.images.cascadia

    containerOptions = {

        def options = ''
        if (params.cascadia.use_gpu) {
            if (workflow.containerEngine == "singularity" || workflow.containerEngine == "apptainer") {
                options += ' --nv'
            } else if (workflow.containerEngine == "docker") {
                options += ' --gpus all'
            }
        }

        return options
    }

    // don't melt the GPU
    maxForks params.cascadia.use_gpu ? 1 : null

    input:
        path ms_file

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        tuple(path(ms_file), path("${ms_file.baseName}.ssl"), emit: ssl)
        path("${ms_file.baseName}.ssl"), emit: published_ssl
        path("cascadia_version.txt"), emit: version
        path("output_file_stats_${ms_file.baseName}.txt"), emit: output_file_stats

    script:

        """
        cascadia sequence ${ms_file} /usr/local/bin/cascadia.ckpt --score_threshold ${params.cascadia.score_threshold} --out ${ms_file.baseName}
            > >(tee "${ms_file.baseName}.stdout") 2> >(tee "${ms_file.baseName}.stderr" >&2)

        echo "${params.images.cascadia}" | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "cascadia_version=%s\n" > cascadia_version.txt

        md5sum '${ms_file.join('\' \'')}' ${ms_file.baseName}.ssl | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' '${ms_file.join('\' \'')}' ${ms_file.baseName}.ssl | sort > sizes.txt
        join -t\$'\\t' hashes.txt sizes.txt > output_file_stats_${ms_file.baseName}.txt
        """

    stub:
        """
        touch "${ms_file.baseName}.ssl"
        touch stub.stderr stub.stdout
        echo "${params.images.cascadia}" | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "cascadia_version=%s\n" > cascadia_version.txt

        md5sum '${ms_file.join('\' \'')}' "${ms_file.baseName}.ssl" | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' '${ms_file.join('\' \'')}' "${ms_file.baseName}.ssl" | sort > sizes.txt
        join -t\$'\\t' hashes.txt sizes.txt > output_file_stats_${ms_file.baseName}.txt
        """
}

process CASCADIA_FIX_SCAN_NUMBERS {
    publishDir params.output_directories.cascadia, failOnError: true, mode: 'copy'
    label 'process_medium'
    container params.images.cascadia_utils

    input:
        tuple path(ms_file), path(ssl_file)

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${ssl_file.baseName}.fixed.ssl"), emit: fixed_ssl
        path("cascadia-utils_version.txt"), emit: version
        path("output_file_stats.txt"), emit: output_file_stats

    script:

        """
        python3 /usr/local/bin/fix_scan_numbers.py ${ssl_file} ${ms_file} ${ssl_file.baseName}.fixed.ssl
            > >(tee "fix_scan_numbers.stdout") 2> >(tee "fix_scan_numbers.stderr" >&2)

        echo "${params.images.cascadia_utils}" | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "cascadia-utils_version=%s\n" > cascadia-utils_version.txt

        md5sum ${ms_file} ${ssl_file} ${ssl_file.baseName}.fixed.ssl | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' ${ms_file} ${ssl_file} ${ssl_file.baseName}.fixed.ssl | sort > sizes.txt
        join -t\$'\\t' hashes.txt sizes.txt > output_file_stats.txt
        """

    stub:
        """
        touch "${ssl_file.baseName}.fixed.ssl" stub.stderr stub.stdout
        echo "${params.images.cascadia_utils}" | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "cascadia-utils_version=%s\n" > cascadia-utils_version.txt

        md5sum ${ms_file} ${ssl_file} "${ssl_file.baseName}.fixed.ssl" | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' ${ms_file} ${ssl_file} "${ssl_file.baseName}.fixed.ssl" | sort > sizes.txt
        join -t\$'\\t' hashes.txt sizes.txt > output_file_stats.txt
        """
}

process CASCADIA_CREATE_FASTA {
    publishDir params.output_directories.cascadia, failOnError: true, mode: 'copy'
    label 'process_medium'
    container params.images.cascadia_utils

    input:
        path ssl_file

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${ssl_file.baseName}.fasta"), emit: fasta
        path("cascadia-utils_version.txt"), emit: version
        path("output_file_stats.txt"), emit: output_file_stats

    script:

        """
        python3 /usr/local/bin/create_fasta_from_ssl.py ${ssl_file} ${ssl_file.baseName}.fasta
            > >(tee "create_fasta.stdout") 2> >(tee "create_fasta.stderr" >&2)

        echo "${params.images.cascadia_utils}" | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "cascadia-utils_version=%s\n" > cascadia-utils_version.txt

        md5sum ${ssl_file} ${ssl_file.baseName}.fasta | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' ${ssl_file} ${ssl_file.baseName}.fasta | sort > sizes.txt
        join -t\$'\\t' hashes.txt sizes.txt > output_file_stats.txt
        """

    stub:
        """
        touch "${ssl_file.baseName}.fasta" stub.stderr stub.stdout
        echo "${params.images.cascadia_utils}" | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "cascadia-utils_version=%s\n" > cascadia-utils_version.txt

        md5sum "${ssl_file.baseName}.fasta" | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' "${ssl_file.baseName}.fasta" | sort > sizes.txt
        join -t\$'\\t' hashes.txt sizes.txt > output_file_stats.txt
        """
}

process CASCADIA_COMBINE_SSL_FILES {
    publishDir params.output_directories.cascadia, failOnError: true, mode: 'copy'
    label 'process_medium'
    container params.images.cascadia_utils

    input:
        path ssl_files

    output:
        path("combined.ssl"), emit: ssl
        path("output_file_stats.txt"), emit: output_file_stats

    script:

        """
        python3 /usr/local/bin/combine_ssl_files.py *.ssl > combined.ssl

        md5sum '${ssl_files.join('\' \'')}' combined.ssl | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' '${ssl_files.join('\' \'')}' combined.ssl | sort > sizes.txt
        join -t\$'\\t' hashes.txt sizes.txt > output_file_stats.txt
        """

    stub:
        """
        touch combined.ssl

        md5sum '${ssl_files.join('\' \'')}' combined.ssl | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' '${ssl_files.join('\' \'')}' combined.ssl | sort > sizes.txt
        join -t\$'\\t' hashes.txt sizes.txt > output_file_stats.txt
        """
}

process BLIB_BUILD_LIBRARY {
    publishDir params.output_directories.cascadia, failOnError: true, mode: 'copy'
    label 'process_medium'
    container params.images.bibliospec

    input:
        path ssl
        path mzml_files

    output:
        path('lib.blib'), emit: blib

    script:
        """
        BlibBuild "${ssl}" lib_redundant.blib
        BlibFilter -b 1 lib_redundant.blib lib.blib
        """

    stub:
        """
        touch lib.blib
        """
}
