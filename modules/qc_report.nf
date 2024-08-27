
def format_flag(var, flag) {
    ret = (var == null ? "" : "${flag} ${var}")
    return ret
}

def format_flags(vars, flag) {
    if(vars instanceof List) {
        return (vars == null ? "" : "${flag} \'${vars.join('\' ' + flag + ' \'')}\'")
    }
    return format_flag(vars, flag)
}

process MAKE_EMPTY_FILE {
    container params.images.ubuntu
    label 'process_low'

    input:
        val file_name

    output:
        path("${file_name}")

    script:
    """
    touch ${file_name}
    """
}

process PARSE_REPORTS {
    publishDir "${params.result_dir}/qc_report", failOnError: true, mode: 'copy'
    label 'process_high_memory'
    container params.images.qc_pipeline

    input:
        path replicate_report
        path precursor_report
        path replicate_metadata

    output:
        path('*.db3'), emit: qc_report_db
        path('*.qmd'), emit: qc_report_qmd
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr
        path('dia_qc_version.txt'), emit: version

    script:
    def metadata_arg = replicate_metadata.name == 'EMPTY' ? '' : "-m $replicate_metadata"

    if(params.qc_report.normalization_method == null)
        """
        dia_qc parse --ofname qc_report_data.db3 ${metadata_arg} \
            --groupBy ${params.skyline.group_by_gene ? 'gene' : 'protein'} \
            '${replicate_report}' '${precursor_report}' \
            > >(tee "parse_data.stdout") 2> >(tee "parse_data.stderr")

        dia_qc qc_qmd ${format_flags(params.qc_report.standard_proteins, '--addStdProtein')} \
            ${format_flags(params.qc_report.color_vars, '--addColorVar')} \
            qc_report_data.db3 \
            > >(tee "make_qmd.stdout") 2> >(tee "make_qmd.stderr")

        # get dia_qc version and git info
        dia_qc --version|awk '{print \$3}'|xargs -0 printf 'dia_qc_version=%s' > dia_qc_version.txt
        echo "dia_qc_git_repo='\$GIT_REPO - \$GIT_BRANCH [\$GIT_SHORT_HASH]'" >> dia_qc_version.txt
        """

    else
        """
        dia_qc parse --ofname qc_report_data.db3 ${metadata_arg} \
            --groupBy ${params.skyline.group_by_gene ? 'gene' : 'protein'} \
            '${replicate_report}' '${precursor_report}' \
            > >(tee "parse_data.stdout") 2> >(tee "parse_data.stderr")

        dia_qc normalize -m=${params.qc_report.normalization_method} qc_report_data.db3 \
            > >(tee "normalize_db.stdout") 2> >(tee "normalize_db.stderr" >&2)

        dia_qc qc_qmd ${format_flags(params.qc_report.standard_proteins, '--addStdProtein')} \
            ${format_flags(params.qc_report.color_vars, '--addColorVar')} \
            qc_report_data.db3 \
            > >(tee "make_qmd.stdout") 2> >(tee "make_qmd.stderr")

        # get dia_qc version and git info
        dia_qc --version|awk '{print \$3}'|xargs -0 printf 'dia_qc_version=%s' > dia_qc_version.txt
        echo "dia_qc_git_repo='\$GIT_REPO - \$GIT_BRANCH [\$GIT_SHORT_HASH]'" >> dia_qc_version.txt
        """

    stub:
    """
    touch stub.stdout stub.stderr stub.db3 stub.qmd

    # get dia_qc version and git info
    dia_qc --version|awk '{print \$3}'|xargs -0 printf 'dia_qc_version=%s' > dia_qc_version.txt
    echo "dia_qc_git_repo='\$GIT_REPO - \$GIT_BRANCH [\$GIT_SHORT_HASH]'" >> dia_qc_version.txt
    """
}

process EXPORT_TABLES {
    publishDir "${params.result_dir}/qc_report/tables", pattern: '*.tsv', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stdout', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stderr', failOnError: true, mode: 'copy'
    label 'process_high_memory'
    container params.images.qc_pipeline

    input:
        path precursor_db

    output:
        path('*.tsv'), emit: tables
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
    """
    dia_qc db_export --precursorTables=30 --proteinTables=30 ${precursor_db} \
        > >(tee "export_tables.stdout") 2> >(tee "export_tables.stderr")
    """

    stub:
    """
    touch stub.stdout stub.stderr stub.tsv
    """
}

process RENDER_QC_REPORT {
    publishDir "${params.result_dir}/qc_report", pattern: 'qc_report.*', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stdout', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stderr', failOnError: true, mode: 'copy'
    label 'process_high_memory'
    container params.images.qc_pipeline

    input:
        path qmd
        path database
        val report_format

    output:
        path("qc_report.${report_format}"), emit: qc_report
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
    """
    quarto render qc_report.qmd --to '${report_format}' \
        > >(tee "render_${report_format}_report.stdout") 2> >(tee "render_${report_format}_report.stderr")
    """

    stub:
    """
    touch "qc_report.${report_format}"
    touch stub.stdout stub.stderr
    """
}

