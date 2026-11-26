
include { get_total_file_sizes } from './utils.nf'
include { get_n_files } from './utils.nf'

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

/**
 * File names a DIA-NN search stub should emit for its precursor report and spectral library.
 *
 * DIA-NN 1.8.x writes a TSV report and a `.tsv.speclib`. Later versions (seen with 1.9.2 and
 * 2.3.0) write a parquet report and a `.parquet.skyline.speclib`. The real script blocks detect
 * which one DIA-NN produced. A stub has nothing to detect, so it goes by the version in the
 * `images.diann` tag: a version below 1.9 (the default image is 1.8.1) gets the 1.8.x names,
 * anything else, including a tag with no recognizable version, gets the newer names.
 *
 * @param output_report_name The base name of the report, e.g. 'quant'.
 * @return Map with the keys `report` and `speclib`.
 */
def diann_stub_output_names(String output_report_name) {
    def image_tag = params.images.diann.toString().tokenize(':').last()
    def version_match = (image_tag =~ /(\d+)\.(\d+)/)
    def tsv_names = false
    if (version_match.find()) {
        def major = version_match.group(1).toInteger()
        def minor = version_match.group(2).toInteger()
        tsv_names = major < 1 || (major == 1 && minor < 9)
    }
    if (tsv_names) {
        return [report: "${output_report_name}.tsv",
                speclib: "${output_report_name}.tsv.speclib"]
    }
    return [report: "${output_report_name}.parquet",
            speclib: "${output_report_name}.parquet.skyline.speclib"]
}

process DIANN_BUILD_LIB {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    label 'process_high'
    container params.images.diann
    cache 'deep' // base this on file content

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
            --threads ${task.cpus} \
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
    stageInMode {
        if (!params.use_vendor_raw) return 'symlink'
        if (params.vendor_raw_copy) return 'copy'
        def staged = ms_files instanceof Collection ? ms_files : [ms_files]
        staged.any { it.name.endsWith('.d') } ? 'symlink' : 'link'
    }
    cache 'lenient'

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

        diann_version=\$(awk 'NR > 2 { exit } match(\$0, /[0-9]+(\\.[0-9]+)+/) { print substr(\$0, RSTART, RLENGTH); exit }' diann.stdout)
        echo "diann_version=\${diann_version:-unknown}" > diann_version.txt
        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """

    stub:
        def stub_names = diann_stub_output_names(output_report_name)
        """
        touch ${stub_names.speclib} ${stub_names.report} stub.quant
        touch stub.stderr stub.stdout
        echo "diann_version=stub" > diann_version.txt

        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """
}

process CARAFE_DIANN_SEARCH {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    label 'process_high'
    container params.images.diann
    cache 'lenient'

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

        /*
         * Parse version from container image tag (e.g., "quay.io/protio/diann:1.8.1" -> "1.8.1")
         * Include --export-quant for version >= 2.0.0, or by default if version cannot be parsed
         */
        def imageTag = params.images.diann.tokenize(':').last()
        def versionParts = imageTag.tokenize('.')
        def major = versionParts[0]?.isInteger() ? versionParts[0].toInteger() : null
        def exportQuantParam = (major == null || major >= 2) ? "--export-quant" : ""

        """
        diann ${ms_file_args} \
            --threads ${task.cpus} \
            --fasta ${fasta_file} \
            --lib ${spectral_library} \
            --gen-spec-lib --reanalyse \
            ${diann_params} \
            ${exportQuantParam} \
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
        def stub_names = diann_stub_output_names(output_report_name)
        """
        touch ${stub_names.speclib} ${stub_names.report} stub.quant
        touch stub.stderr stub.stdout

        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """
}

process DIANN_QUANT {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    cpus   8
    memory { Math.max(16.0, ((ms_file.size() + spectral_library.size()) / (1024 ** 3)) * 2.0).GB }
    time   { 4.h * task.attempt }
    container params.images.diann
    stageInMode {
        if (!params.use_vendor_raw) return 'symlink'
        if (params.vendor_raw_copy) return 'copy'
        ms_file.name.endsWith('.d') ? 'symlink' : 'link'
    }
    cache 'lenient'

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
    memory { Math.max(32.0, (get_total_file_sizes(ms_files) / (1024 ** 3)) * 2.0).GB }
    time   { 15.m * get_n_files(ms_files) }
    container params.images.diann
    stageInMode {
        if (!params.use_vendor_raw) return 'symlink'
        if (params.vendor_raw_copy) return 'copy'
        def staged = ms_files instanceof Collection ? ms_files : [ms_files]
        staged.any { it.name.endsWith('.d') } ? 'symlink' : 'link'
    }
    cache 'lenient'

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

        diann_version=\$(awk 'NR > 2 { exit } match(\$0, /[0-9]+(\\.[0-9]+)+/) { print substr(\$0, RSTART, RLENGTH); exit }' diann.stdout)
        echo "diann_version=\${diann_version:-unknown}" > diann_version.txt
        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """

    stub:
        def stub_names = diann_stub_output_names(output_report_name)
        """
        touch ${stub_names.speclib} ${stub_names.report}
        touch stub.stderr stub.stdout
        echo "diann_version=stub" > diann_version.txt

        ${generate_diann_output_file_stats_script(ms_files.toList(), output_report_name)}
        """
}

def get_blib_name() {
    if( params.skyline.document_name != null ){
        return "${params.skyline.document_name}_diann_lib.blib"
    }
    return 'lib.blib'
}

/**
 * Shell commands that give the DIA-NN speclib and precursor report the file names BlibBuild
 * pairs up, and set the shell variable `blib_build_input` to the file to pass to BlibBuild.
 *
 * BlibBuild is given only the speclib. It derives the name of the precursor report it also
 * needs from the speclib's file name:
 *
 *   <name>-lib.parquet.skyline.speclib  ->  <name>.parquet       (DIA-NN 2.x)
 *   <name>-lib.tsv.speclib              ->  <name>-report.tsv    (DIA-NN 1.8.x)
 *
 * The search steps publish `<name>.parquet.skyline.speclib` + `<name>.parquet` for DIA-NN 2.x
 * (and 1.9.2, which uses the same names) and `<name>.tsv.speclib` + `<name>.tsv` for DIA-NN
 * 1.8.x, so the staged copies are renamed
 * here. Used by both the script and the stub of BLIB_BUILD_LIBRARY so that stub runs exercise
 * the same file handling as real runs.
 */
def blib_build_input_script(speclib, precursor_report) {
    return """\
speclib='${speclib}'
precursor_report='${precursor_report}'
case "\$speclib" in
    *.parquet.skyline.speclib)
        # DIA-NN 2.x
        blib_build_input="\${speclib%.parquet.skyline.speclib}-lib.parquet.skyline.speclib"
        expected_report="\${speclib%.parquet.skyline.speclib}.parquet"
        ;;
    *.tsv.speclib)
        # DIA-NN 1.8.x
        blib_build_input="\${speclib%.tsv.speclib}-lib.tsv.speclib"
        expected_report="\${speclib%.tsv.speclib}-report.tsv"
        ;;
    *)
        echo "Unrecognized DIA-NN spectral library name: '\$speclib'." \
             "Expected '*.parquet.skyline.speclib' (DIA-NN 2.x) or '*.tsv.speclib' (DIA-NN 1.8.x)." >&2
        exit 1
        ;;
esac
mv -v "\$speclib" "\$blib_build_input"
if [[ "\$precursor_report" != "\$expected_report" ]] ; then
    mv -v "\$precursor_report" "\$expected_report"
fi
"""
}

process BLIB_BUILD_LIBRARY {
    publishDir params.output_directories.diann, failOnError: true, mode: 'copy'
    cpus   2
    memory { Math.max(32.0, (precursor_report.size() / (1024 ** 3)) * 5 ).GB }
    time   { 2.h * task.attempt }
    label 'proteowizard'
    container params.images.proteowizard

    input:
        path speclib
        path precursor_report

    output:
        path { get_blib_name() }, emit: blib

    script:
        """
        # ensure the speclib and precursor report have filenames that will allow BlibBuild to match them
        ${blib_build_input_script(speclib, precursor_report)}

        wine BlibBuild "\$blib_build_input" "${get_blib_name()}"
        """

    stub:
        """
        ${blib_build_input_script(speclib, precursor_report)}

        touch "${get_blib_name()}"
        """
}
