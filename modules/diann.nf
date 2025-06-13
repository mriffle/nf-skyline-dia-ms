
/**
 * Join multiple MS files into a single string, skipping Bruker .d directories.
 *
 * @param ms_files MS file names. Can either be a single string or List.
 */
def join_ms_files(ms_files) {
    def ms_file_list = ms_files instanceof List ? ms_files : [ms_files]
    return ms_file_list.findAll { !it.toString().endsWith('.d') }
                       .collect { "'${it}'" }
                       .join(' ')
}

def generate_diann_output_file_stats_script(List ms_files, String report_name) {
    def command = """stat_files=()
[[ -f ${report_name}.tsv ]] && stat_files+=(${report_name}.tsv)
[[ -f ${report_name}.parquet ]] && stat_files+=(${report_name}.parquet)
[[ \${#stat_files[@]} -eq 1 ]] || \
    { echo "Expected exactly one match for precursor report, found \${#stat_files[@]}" >&2; exit 1; }

shopt -s nullglob
for f in ${join_ms_files(ms_files)} ${report_name}*.speclib *.quant ; do
    stat_files+=("\$f")
done
shopt -u nullglob

printf "%s\\n" "\${stat_files[@]}" | while IFS= read -r file; do
    md5sum "\$file" | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\2\\t\\1/'
done | sort > hashes.txt
printf "%s\\n" "\${stat_files[@]}" | while IFS= read -r file; do
    stat -L --printf='%n\\t%s\\n' "\$file"
done | sort > sizes.txt

join -t\$'\\t' hashes.txt sizes.txt > output_file_stats.txt
    """
    return command
}

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
    stageInMode { params.use_vendor_raw ? 'link' : 'symlink' }

    input:
        path ms_files
        path fasta_file
        path spectral_library
        val output_report_name
        val diann_params

    output:
        path("*.stderr"), emit: stderr
        path("*.stdout"), emit: stdout
        path("${output_report_name}*.speclib"), emit: speclib
        path("${output_report_name}.{parquet,tsv}"), emit: precursor_report
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
            --gen-spec-lib --reanalyse \
            ${diann_params} \
            > >(tee "diann.stdout") 2> >(tee "diann.stderr" >&2)

        # DiaNN does weird things with output file names depending on the version
        # Instead of specifying them as options to DiaNN we will rename the default output files manually
        if [[ -f report.tsv && -f lib.tsv.speclib ]] ; then
            mv -nv report.tsv ${output_report_name}.tsv
            mv -nv lib.tsv.speclib ${output_report_name}.tsv.speclib
        elif [[ -f report.parquet && -f report-lib.parquet.skyline.speclib ]] ; then
            mv -nv report.parquet ${output_report_name}.parquet
            mv -nv report-lib.parquet.skyline.speclib ${output_report_name}.parquet.skyline.speclib
        else
            echo "Missing DiaNN precursor report and/or speclib!" >&2
            exit 1
        fi

        head -n 2 diann.stdout | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "diann_version=%s\\n" > diann_version.txt
        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """

    stub:
        """
        touch ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet stub.quant
        touch stub.stderr stub.stdout
        diann | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+'| head -1 | xargs printf "diann_version=%s\\n" > diann_version.txt

        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """
}

process CARAFE_DIANN_SEARCH {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    label 'process_high'
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
        path("${output_report_name}.{parquet,tsv}"), emit: precursor_report
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
            --gen-spec-lib --reanalyse \
            ${diann_params} \
            > >(tee "diann.stdout") 2> >(tee "diann.stderr" >&2)

        # DiaNN does weird things with output file names depending on the version
        # Instead of specifying them as options to DiaNN we will rename the default output files manually
        if [[ -f report.tsv ]] ; then
            mv -nv report.tsv ${output_report_name}.tsv
        elif [[ -f report.parquet ]] ; then
            mv -nv report.parquet ${output_report_name}.parquet
        else
            echo "Missing DiaNN precursor report and/or speclib!" >&2
            exit 1
        fi

        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """

    stub:
        """
        touch ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet stub.quant
        touch stub.stderr stub.stdout

        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """
}

process DIANN_QUANT {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    cpus   8
    memory { Math.max(8.0, ((ms_file.size() + spectral_library.size()) / (1024 ** 3)) * 1.5).GB }
    time   { 2.h * task.attempt }
    label 'DIANN_QUANT'
    container params.images.diann
    stageInMode { params.use_vendor_raw ? 'link' : 'symlink' }

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
    cpus   32
    memory { Math.max(16.0, (ms_files*.size().sum() / (1024 ** 3)) * 1.5).GB }
    time   { 6.m * ms_files.size() }
    label 'DIANN_MBR'
    container params.images.diann
    stageInMode { params.use_vendor_raw ? 'link' : 'symlink' }

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
        path("${output_report_name}*.speclib"), emit: speclib
        path("${output_report_name}.{parquet,tsv}"), emit: precursor_report
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
        echo "There are ${ms_files.size()} files!"

        diann ${ms_file_args} \
            --threads ${task.cpus} \
            --fasta ${fasta_file} \
            --lib ${spectral_library} \
            --use-quant --gen-spec-lib --reanalyse \
            ${diann_params} \
            > >(tee "diann.stdout") 2> >(tee "diann.stderr" >&2)

        # DiaNN does weird things with output file names depending on the version
        # Instead of specifying them as options to DiaNN we will rename the default output files manually
        if [[ -f report.tsv && -f lib.tsv.speclib ]] ; then
            mv -nv report.tsv ${output_report_name}.tsv
            mv -nv lib.tsv.speclib ${output_report_name}.tsv.speclib
        elif [[ -f report.parquet && -f report-lib.parquet.skyline.speclib ]] ; then
            mv -nv report.parquet ${output_report_name}.parquet
            mv -nv report-lib.parquet.skyline.speclib ${output_report_name}.parquet.skyline.speclib
        else
            echo "Missing DiaNN precursor report and/or speclib!" >&2
            exit 1
        fi

        head -n 2 diann.stdout | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+' | xargs printf "diann_version=%s\\n" > diann_version.txt
        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """

    stub:
        """
        touch ${output_report_name}.parquet.skyline.speclib ${output_report_name}.parquet
        touch stub.stderr stub.stdout
        diann | egrep -o '[0-9]+\\.[0-9]+\\.[0-9]+'| head -1 | xargs printf "diann_version=%s\\n" > diann_version.txt

        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """
}

process BLIB_BUILD_LIBRARY {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    cpus   2
    memory { Math.max(8.0, (precursor_report.size() / (1024 ** 3)) * 1.5 ).GB }
    time   { 2.h * task.attempt }
    label 'proteowizard'
    label 'BLIB_BUILD_LIBRARY'
    container params.images.proteowizard

    input:
        path speclib
        path precursor_report

    output:
        path('lib.blib'), emit: blib

    script:
        """
        wine BlibBuild "${speclib}" lib.blib
        """

    stub:
        """
        touch lib.blib
        """
}
