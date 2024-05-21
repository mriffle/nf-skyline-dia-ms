
include { SKYLINE_RUN_REPORTS } from "../modules/skyline.nf"
include { GENERATE_DIA_QC_REPORT_DB } from "../modules/qc_report.nf"
include { RENDER_QC_REPORT } from "../modules/qc_report.nf"
include { EXPORT_TABLES } from "../modules/qc_report.nf"

// include { UNZIP_SKY_FILE } from "../modules/skyline.nf"

workflow generate_dia_qc_report {

    take:
        sky_zip_file
        replicate_metadata

    emit:
        qc_reports
        qc_report_qmd
        qc_report_db
        qc_tables

    main:

        // export skyline reports
        skyr_files = Channel.fromList([params.qc_report.replicate_report_template,
                                       params.qc_report.precursor_report_template]).map{ file(it) }
        SKYLINE_RUN_REPORTS(sky_zip_file, skyr_files.collect())
        sky_reports = SKYLINE_RUN_REPORTS.out.skyline_report_files.flatten().map{ it -> tuple(it.name, it) }
        precursor_report = sky_reports.filter{ it[0] =~ /^precursor_quality\.report\.tsv$/ }.map{ it -> it[1] }
        replicate_report = sky_reports.filter{ it[0] =~ /^replicate_quality\.report\.tsv$/ }.map{ it -> it[1] }

        GENERATE_DIA_QC_REPORT_DB(replicate_report,
                                  precursor_report,
                                  replicate_metadata)

        qc_report_qmd = GENERATE_DIA_QC_REPORT_DB.out.qc_report_qmd
        qc_report_db = GENERATE_DIA_QC_REPORT_DB.out.qc_report_db

        report_formats = Channel.from(['html', 'pdf'])
        RENDER_QC_REPORT(GENERATE_DIA_QC_REPORT_DB.out.qc_report_qmd,
                         GENERATE_DIA_QC_REPORT_DB.out.qc_report_db,
                         report_formats)
        qc_reports = RENDER_QC_REPORT.out.qc_report

        if(params.qc_report.export_tables) {
            EXPORT_TABLES(GENERATE_DIA_QC_REPORT_DB.out.qc_report_db)
            qc_tables = EXPORT_TABLES.out.tables
        } else {
            qc_tables = Channel.empty()
        }
}

