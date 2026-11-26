// subworkflows
include { generate_dia_qc_report } from "../subworkflows/generate_qc_report"
include { skyline_import } from "../subworkflows/skyline_import"
include { skyline_reports } from "../subworkflows/skyline_run_reports"

// modules
include { EXPORT_GENE_REPORTS } from "../modules/qc_report"

// functions
include { get_final_skyline_doc_name } from "../subworkflows/skyline_import"
include { check_final_skyline_doc_names } from "../subworkflows/skyline_import"
include { resolve_user_path } from "../modules/utils.nf"

workflow skyline {
    take:
        ms_file_ch
        skyline_template_zipfile
        fasta
        replicate_metadata
        skyline_document_name
        final_speclib
        pdc_study_name
        skyr_files
        use_batch_mode
        batch_name_list

    main:

        if(!params.skyline.skip) {

            // Fail before any task runs if two batches would write the same document.
            check_final_skyline_doc_names(batch_name_list)

            // create Skyline document
            if(skyline_template_zipfile != null) {
                skyline_import(
                    skyline_template_zipfile,
                    fasta,
                    final_speclib,
                    ms_file_ch,
                    replicate_metadata,
                    skyline_document_name
                )
                proteowizard_version = skyline_import.out.proteowizard_version
            }

            final_skyline_file = skyline_import.out.skyline_results
            final_skyline_hash = skyline_import.out.skyline_results_hash

            // Map Skyline documents to batch names. Each batch is keyed by the file name its
            // final document is given, computed from the document and batch name. Nothing is
            // derived from the file names the processes produce, so a document or batch name
            // that looks like a step suffix (or ends in an underscore) cannot break the match.
            batched_skyline_files = Channel.fromList(batch_name_list)
                .combine(skyline_document_name)
                .map{ it, doc_name -> ["${get_final_skyline_doc_name(doc_name, it)}.sky.zip".toString(), it] }
                .join(final_skyline_file.map{ it -> [it.name, it] },
                      failOnMismatch: true, failOnDuplicate: true)
                .map{ it -> [it[1], it[2]] }

            // generate QC report
            if(!params.qc_report.skip || !params.batch_report.skip) {
                generate_dia_qc_report(batched_skyline_files, replicate_metadata)
                dia_qc_version = generate_dia_qc_report.out.dia_qc_version
                qc_report_files = generate_dia_qc_report.out.qc_reports.concat(
                    generate_dia_qc_report.out.qc_report_qmd,
                    generate_dia_qc_report.out.qc_report_db,
                    generate_dia_qc_report.out.qc_tables
                )

                // Export PDC gene tables
                if(params.pdc.gene_level_data != null) {
                    gene_level_data = resolve_user_path(params.pdc.gene_level_data, 'pdc.gene_level_data')
                    EXPORT_GENE_REPORTS(generate_dia_qc_report.out.qc_report_db,
                                        gene_level_data,
                                        pdc_study_name)
                    EXPORT_GENE_REPORTS.out.gene_reports | flatten | set{ gene_reports }
                } else {
                    gene_reports = Channel.empty()
                }
            } else {
                dia_qc_version = Channel.empty()
                qc_report_files = Channel.empty()
                gene_reports = Channel.empty()
            }

            // run reports if requested
            skyline_reports_ch = null;
            if(params.skyline.skyr_file) {
                skyline_reports(
                    batched_skyline_files,
                    skyr_files
                )
                skyline_reports_ch = skyline_reports.out.skyline_report_files
                    .map{ it -> it[1] }
                    .flatten()
            } else {
                skyline_reports_ch = Channel.empty()
            }

        } else {
            // skip skyline
            proteowizard_version = Channel.empty()
            final_skyline_file = Channel.empty()
            final_skyline_hash = Channel.empty()
            skyline_reports_ch = Channel.empty()
            qc_report_files = Channel.empty()
            dia_qc_version = Channel.empty()
            gene_reports = Channel.empty()
        }

    emit:
        proteowizard_version
        final_skyline_file
        final_skyline_hash
        skyline_reports_ch
        qc_report_files
        dia_qc_version
        gene_reports
}
