// Modules
include { SKYLINE_ADD_LIB } from "../modules/skyline"
include { SKYLINE_IMPORT_MZML } from "../modules/skyline"
include { SKYLINE_MERGE_RESULTS } from "../modules/skyline"
include { ANNOTATION_TSV_TO_CSV } from "../modules/skyline"
include { SKYLINE_MINIMIZE_DOCUMENT } from "../modules/skyline"
include { SKYLINE_ANNOTATE_DOCUMENT } from "../modules/skyline"

workflow skyline_import {

    take:
        skyline_template_zipfile
        fasta
        library
        ms_file_ch
        replicate_metadata
        skyline_document_name
        use_batch_mode

    main:

        // add library to skyline file
        SKYLINE_ADD_LIB(skyline_template_zipfile, fasta, library)
        skyline_zipfile = SKYLINE_ADD_LIB.out.skyline_zipfile

        // import spectra into skyline file
        SKYLINE_IMPORT_MZML(skyline_zipfile, ms_file_ch)

        if(use_batch_mode == true){
            error "Batch mode is not implemented yet!"
        } else {
            // merge sky files
            skyd_file_ch = SKYLINE_IMPORT_MZML.out.skyd_file.map { it -> it[1] }
            flat_ms_file_ch = ms_file_ch.map { it -> it[1] }
            SKYLINE_MERGE_RESULTS(
                skyline_zipfile,
                skyd_file_ch.collect(),
                flat_ms_file_ch.collect(),
                fasta,
                skyline_document_name
            )
        }

        if(params.replicate_metadata != null || params.pdc.study_id != null) {
            ANNOTATION_TSV_TO_CSV(replicate_metadata)

            SKYLINE_ANNOTATE_DOCUMENT(SKYLINE_MERGE_RESULTS.out.final_skyline_zipfile,
                                      ANNOTATION_TSV_TO_CSV.out.annotation_csv,
                                      ANNOTATION_TSV_TO_CSV.out.annotation_definitions)

            skyline_results = SKYLINE_ANNOTATE_DOCUMENT.out.final_skyline_zipfile
            skyline_results_hash = SKYLINE_ANNOTATE_DOCUMENT.out.output_file_hashes
        } else {
            skyline_results = SKYLINE_MERGE_RESULTS.out.final_skyline_zipfile
            skyline_results_hash = SKYLINE_MERGE_RESULTS.out.output_file_hashes
        }

        if(params.skyline.minimize) {
            SKYLINE_MINIMIZE_DOCUMENT(skyline_results)
            skyline_minimized_results = SKYLINE_MINIMIZE_DOCUMENT.out.final_skyline_zipfile
            skyline_minimized_results_hash = SKYLINE_MINIMIZE_DOCUMENT.out.output_file_hashes
        } else {
            skyline_minimized_results = Channel.empty()
            skyline_minimized_results_hash = Channel.empty()
        }

    emit:
        skyline_results
        skyline_results_hash
        skyline_minimized_results
        skyline_minimized_results_hash
        proteowizard_version = SKYLINE_ADD_LIB.out.version
}
