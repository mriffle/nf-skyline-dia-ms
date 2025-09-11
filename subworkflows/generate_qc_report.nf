
include { SKYLINE_RUN_REPORTS } from "../modules/skyline.nf"
include { MERGE_REPORTS } from "../modules/qc_report.nf"
include { FILTER_IMPUTE_NORMALIZE } from "../modules/qc_report.nf"
include { GENERATE_QC_QMD } from "../modules/qc_report.nf"
include { RENDER_QC_REPORT } from "../modules/qc_report.nf"
include { GENERATE_BATCH_REPORT } from "../modules/qc_report.nf"
include { EXPORT_TABLES } from "../modules/qc_report.nf"

def run_impute_normalize() {
    return params.qc_report.normalization_method != null ||
           params.qc_report.imputation_method != null ||
           params.qc_report.exclude_projects != null ||
           params.qc_report.exclude_projects != null
}

workflow generate_dia_qc_report {

    take:
        sky_zip_files
        replicate_metadata

    main:
        // export skyline reports
        skyr_files = Channel.fromList([params.qc_report.replicate_report_template,
                                       params.qc_report.precursor_report_template]).map{ file(it, checkIfExists: true) }
        SKYLINE_RUN_REPORTS(sky_zip_files, skyr_files.collect())

        // Rearange skyline report channels before calling MERGE_REPORTS
        sky_reports = SKYLINE_RUN_REPORTS.out.skyline_report_files
            .transpose()
            .map{ batch, file -> tuple(batch, file.name, file) }
        sky_reports
            .filter{ it[1] =~ /replicate_quality\.report\.tsv$/ }
            .map{ batch, file_name, file -> [batch, file] }
            .join(
                sky_reports
                    .filter{ it[1] =~ /precursor_quality\.report\.tsv$/ }
                    .map{ batch, file_name, file -> [batch, file] },
                failOnMismatch: true, failOnDuplicate: true
            ).set{ batched_sky_reports }

        study_names = batched_sky_reports.map{ it -> it[0] == null ? params.skyline.document_name : it[0] }
        replicate_reports = batched_sky_reports.map{ it -> it[1] }
        precursor_reports = batched_sky_reports.map{ it -> it[2] }

        MERGE_REPORTS(study_names.collect(),
                      replicate_reports.collect(),
                      precursor_reports.collect(),
                      replicate_metadata)

        if (run_impute_normalize()) {
            FILTER_IMPUTE_NORMALIZE(MERGE_REPORTS.out.final_db)
            qc_report_db = FILTER_IMPUTE_NORMALIZE.out.final_db
        } else {
            qc_report_db = MERGE_REPORTS.out.final_db
        }

        // Generate and render QC reports if applicable
        if (!params.qc_report.skip) {
            GENERATE_QC_QMD(study_names, qc_report_db)

            GENERATE_QC_QMD.out.qc_report_qmd
                .combine(Channel.fromList(['html', 'pdf']))
                .set{ render_qc_report_input }

            RENDER_QC_REPORT(render_qc_report_input, qc_report_db)
            qc_reports = RENDER_QC_REPORT.out.qc_report
            qc_report_qmd = GENERATE_QC_QMD.out.qc_report_qmd.map{ it -> it[1] }
        } else {
            qc_reports = Channel.empty()
            qc_report_qmd = Channel.empty()
        }

        // Generate and render batch report of applicable
        if (!params.batch_report.skip) {
            GENERATE_BATCH_REPORT(qc_report_db)

            batch_report = GENERATE_BATCH_REPORT.out.bc_html
            batch_report_rmd = GENERATE_BATCH_REPORT.out.bc_rmd
            batch_report_tables = GENERATE_BATCH_REPORT.out.tsv_reports
        } else {
            batch_report = Channel.empty()
            batch_report_rmd = Channel.empty()
            batch_report_tables = Channel.empty()
        }

        if(params.qc_report.export_tables) {
            EXPORT_TABLES(qc_report_db)
            qc_tables = EXPORT_TABLES.out.tables.flatten()
        } else {
            qc_tables = Channel.empty()
        }


    emit:
        qc_reports
        qc_report_qmd
        qc_report_db
        qc_tables
        batch_report
        batch_report_rmd
        batch_report_tables
        dia_qc_version = MERGE_REPORTS.out.dia_qc_version
}
