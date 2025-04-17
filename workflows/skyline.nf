// subworkflows
include { generate_dia_qc_report } from "../subworkflows/generate_qc_report"
include { skyline_import } from "../subworkflows/skyline_import"
include { skyline_reports } from "../subworkflows/skyline_run_reports"

// modules
include { EXPORT_GENE_REPORTS } from "../modules/qc_report"

// functions
include { get_skyline_doc_name_per_batch } from "../subworkflows/skyline_import"

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

    main:

        if(!params.skyline.skip) {

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

            // Map Skyline documents to batch names
            if (use_batch_mode == true) {
                batch_names = params.quant_spectra_dir.collect{ k, v -> k }
            } else {
                batch_names = [null]
            }
            batched_skyline_files = Channel.fromList(batch_names)
                .map{ it -> [get_skyline_doc_name_per_batch(skyline_document_name, it), it] }
                .join(final_skyline_file.map{ it -> [it.baseName.replaceAll(/(_annotated)?\.sky$/, ''), it] },
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
                    gene_level_data = file(params.pdc.gene_level_data, checkIfExists: true)
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
