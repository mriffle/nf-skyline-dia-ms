
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
    container "${workflow.profile == 'aws' ? 'public.ecr.aws/docker/library/ubuntu:22.04' : 'ubuntu:22.04'}"
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

process GENERATE_DIA_QC_REPORT_DB {
    publishDir "${params.result_dir}/qc_report", pattern: '*.db3', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.qmd', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stdout', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stderr', failOnError: true, mode: 'copy'
    label 'process_high_memory'
    container 'quay.io/mauraisa/dia_qc_report:1.17'

    input:
        path replicate_report
        path precursor_report
        path replicate_metadata

    output:
        path('qc_report_data.db3'), emit: qc_report_db
        path('qc_report.qmd'), emit: qc_report_qmd

    script:
        def metadata_arg = replicate_metadata.name == 'EMPTY' ? '' : "-m $replicate_metadata"
        """
        parse_data --ofname qc_report_data.db3 ${metadata_arg} \
            --groupBy ${params.skyline.group_by_gene ? 'gene' : 'protein'} \
            '${replicate_report}' '${precursor_report}' \
            > >(tee "parse_data.stdout") 2> >(tee "parse_data.stderr")

        normalize_db qc_report_data.db3 \
            > >(tee "normalize_db.stdout") 2> >(tee "normalize_db.stderr" >&2)

        generate_qc_qmd ${format_flags(params.qc_report.standard_proteins, '--addStdProtein')} \
            ${format_flags(params.qc_report.color_vars, '--addColorVar')} \
            qc_report_data.db3 \
            > >(tee "make_qmd.stdout") 2> >(tee "make_qmd.stderr")
        """

    stub:
        """
        touch stub.stdout stub.stderr stub.db3 stub.qmd
        """
}

process EXPORT_TABLES {
    publishDir "${params.result_dir}/qc_report/tables", pattern: '*.tsv', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stdout', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stderr', failOnError: true, mode: 'copy'
    label 'process_high_memory'
    container 'quay.io/mauraisa/dia_qc_report:1.17'

    input:
        path precursor_db

    output:
        path('*.tsv'), emit: tables

    script:
        """
        export_tables --precursorTables=30 --proteinTables=30 ${precursor_db} \
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
    container 'quay.io/mauraisa/dia_qc_report:1.17'

    input:
        path qmd
        path database
        val report_format

    output:
        path("qc_report.${format}"), emit: qc_report

    script:
        format = report_format
        """
        quarto render qc_report.qmd --to '${format}' \
            > >(tee "render_${report_format}_report.stdout") 2> >(tee "render_${report_format}_report.stderr")
        """

    stub:
        """
        touch "qc_report.${format}"
        """
}

