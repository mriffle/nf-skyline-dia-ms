process CASCADIA_SEARCH {
    publishDir params.output_directories.cascadia, failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container params.images.cascadia
    
    input:
        path ms_file
    
    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${ms_file}.ssl"), emit: ssl
        path("cascadia_version.txt"), emit: version
        path("output_file_stats.txt"), emit: output_file_stats

    script:

        """
        cascadia sequence ${ms_file} /usr/local/bin/cascadia.ckpt --out ${ms_file.baseName}
            > >(tee "cascadia.stdout") 2> >(tee "cascadia.stderr" >&2)

        echo "${params.images.cascadia}" | egrep -o '[0-9]+\.[0-9]+\.[0-9]+' | xargs printf "cascadia_version=%s\n" > cascadia_version.txt

        md5sum '${ms_files.join('\' \'')}' ${ms_file}.ssl | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' '${ms_files.join('\' \'')}' ${ms_file}.ssl | sort > sizes.txt
        join -t'\t' hashes.txt sizes.txt > output_file_stats.txt
        """

    stub:
        """
        touch stub.ssl
        touch stub.stderr stub.stdout
        echo "${params.images.cascadia}" | egrep -o '[0-9]+\.[0-9]+\.[0-9]+' | xargs printf "cascadia_version=%s\n" > cascadia_version.txt

        md5sum '${ms_files.join('\' \'')}' stub.ssl | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' '${ms_files.join('\' \'')}' stub.ssl | sort > sizes.txt
        join -t'\t' hashes.txt sizes.txt > output_file_stats.txt
        """
}

process CASCADIA_FIX_SCAN_NUMBERS {
    publishDir params.output_directories.cascadia, failOnError: true, mode: 'copy'
    label 'process_medium'
    container params.images.cascadia_utils
    
    input:
        path ssl_file
    
    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${ssl_file.baseName}.fixed.ssl"), emit: fixed_ssl
        path("cascadia-utils_version.txt"), emit: version
        path("output_file_stats.txt"), emit: output_file_stats

    script:

        """
        python3 /usr/local/bin/fix_scan_numbers.py ${ssl_file} ${ssl_file.baseName}.fixed.ssl
            > >(tee "fix_scan_numbers.stdout") 2> >(tee "fix_scan_numbers.stderr" >&2)

        echo "${params.images.cascadia_utils}" | egrep -o '[0-9]+\.[0-9]+\.[0-9]+' | xargs printf "cascadia-utils_version=%s\n" > cascadia-utils_version.txt

        md5sum ${ssl_file} ${ssl_file.baseName}.fixed.ssl | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' ${ssl_file} ${ssl_file.baseName}.fixed.ssl | sort > sizes.txt
        join -t'\t' hashes.txt sizes.txt > output_file_stats.txt
        """

    stub:
        """
        touch stub.ssl stub.fixed.fasta
        echo "${params.images.cascadia_utils}" | egrep -o '[0-9]+\.[0-9]+\.[0-9]+' | xargs printf "cascadia-utils_version=%s\n" > cascadia-utils_version.txt

        md5sum stub.ssl stub.fixed.fasta | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' stub.ssl stub.fixed.fasta | sort > sizes.txt
        join -t'\t' hashes.txt sizes.txt > output_file_stats.txt
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
        path("cascadia-fasta_version.txt"), emit: version
        path("output_file_stats.txt"), emit: output_file_stats

    script:

        """
        python3 /usr/local/bin/create_fasta_from_ssl.py ${ssl_file} ${ssl_file.baseName}.fasta
            > >(tee "create_fasta.stdout") 2> >(tee "create_fasta.stderr" >&2)

        echo "${params.images.cascadia_utils}" | egrep -o '[0-9]+\.[0-9]+\.[0-9]+' | xargs printf "cascadia-utils_version=%s\n" > cascadia-utils_version.txt

        md5sum ${ssl_file} ${ssl_file.baseName}.fasta | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' ${ssl_file} ${ssl_file.baseName}.fasta | sort > sizes.txt
        join -t'\t' hashes.txt sizes.txt > output_file_stats.txt
        """

    stub:
        """
        touch stub.ssl stub.fasta
        echo "${params.images.cascadia_utils}" | egrep -o '[0-9]+\.[0-9]+\.[0-9]+' | xargs printf "cascadia-utils_version=%s\n" > cascadia-utils_version.txt

        md5sum stub.ssl stub.fasta | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/' | sort > hashes.txt
        stat -L --printf='%n\t%s\n' stub.ssl stub.fasta | sort > sizes.txt
        join -t'\t' hashes.txt sizes.txt > output_file_stats.txt
        """
}

process BLIB_BUILD_LIBRARY {
    publishDir params.output_directories.cascadia, failOnError: true, mode: 'copy'
    label 'process_medium'
    container params.images.bibliospec

    input:
        path ssl

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