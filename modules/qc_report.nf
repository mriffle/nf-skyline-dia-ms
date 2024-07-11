
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

process PARSE_REPORTS {
    publishDir "${params.result_dir}/qc_report", pattern: '*.db3', enabled: params.qc_report.normalization_method == null, failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stdout', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stderr', failOnError: true, mode: 'copy'
    label 'process_high_memory'
    container 'quay.io/mauraisa/dia_qc_report:2.0.0'

    input:
        path replicate_report
        path precursor_report
        path replicate_metadata

    output:
        path('*.db3'), emit: qc_report_db
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        def metadata_arg = replicate_metadata.name == 'EMPTY' ? '' : "-m $replicate_metadata"
        """
        dia_qc parse --ofname qc_report_data.db3 ${metadata_arg} \
            --groupBy ${params.skyline.group_by_gene ? 'gene' : 'protein'} \
            '${replicate_report}' '${precursor_report}' \
            > >(tee "parse_data.stdout") 2> >(tee "parse_data.stderr")
        """

    stub:
        """
        touch stub.stdout stub.stderr stub.db3 stub.qmd
        """
}

process NORMALIZE_DB {
    publishDir "${params.result_dir}/qc_report", pattern: '*.db3', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stdout', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stderr', failOnError: true, mode: 'copy'
    label 'process_high_memory'
    container 'quay.io/mauraisa/dia_qc_report:2.0.0'

    input:
        path qc_report_db

    output:
        path('*_normalized.db3'), emit: qc_report_db
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        """
        # It is necissary to make a copy to avoid breaking nextflow's caching
        cp ${qc_report_db} ${qc_report_db.baseName}_normalized.db3

        dia_qc normalize -m=${params.qc_report.normalization_method} ${qc_report_db.baseName}_normalized.db3 \
            > >(tee "normalize_db.stdout") 2> >(tee "normalize_db.stderr" >&2)
        """

    stub:
        """
        touch stub.stdout stub.stderr stub_normalized.db3
        """
}

process GENERATE_QC_QMD {
    publishDir "${params.result_dir}/qc_report", pattern: '*.qmd', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stdout', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stderr', failOnError: true, mode: 'copy'
    label 'process_high'
    container 'quay.io/mauraisa/dia_qc_report:2.0.0'

    input:
        path qc_report_db

    output:
        path('*.qmd'), emit: qc_report_qmd
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        """
        dia_qc qc_qmd ${format_flags(params.qc_report.standard_proteins, '--addStdProtein')} \
            ${format_flags(params.qc_report.color_vars, '--addColorVar')} \
            ${qc_report_db} \
            > >(tee "make_qmd.stdout") 2> >(tee "make_qmd.stderr")
        """

    stub:
        """
        touch stub.stdout stub.stderr stub.qmd
        """
}

process EXPORT_TABLES {
    publishDir "${params.result_dir}/qc_report/tables", pattern: '*.tsv', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stdout', failOnError: true, mode: 'copy'
    publishDir "${params.result_dir}/qc_report", pattern: '*.stderr', failOnError: true, mode: 'copy'
    label 'process_high_memory'
    container 'quay.io/mauraisa/dia_qc_report:2.0.0'

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
    container 'quay.io/mauraisa/dia_qc_report:2.0.0'

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

