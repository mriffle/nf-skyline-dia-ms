// Modules
include { SKYLINE_ADD_LIB } from "../modules/skyline"
include { SKYLINE_IMPORT_MS_FILE } from "../modules/skyline"
include { SKYLINE_MERGE_RESULTS } from "../modules/skyline"
include { ANNOTATION_TSV_TO_CSV } from "../modules/skyline"
include { SKYLINE_MINIMIZE_DOCUMENT } from "../modules/skyline"
include { SKYLINE_ANNOTATE_DOCUMENT } from "../modules/skyline"

def get_skyline_doc_name_per_batch(document_basename, batch_name) {
    return "${document_basename}${batch_name == null ? '' : '_' + batch_name}"
}

workflow skyline_import {

    take:
        skyline_template_zipfile
        fasta
        library
        ms_file_ch
        replicate_metadata
        skyline_document_name

    main:

        // add library to skyline file
        SKYLINE_ADD_LIB(skyline_template_zipfile, fasta, library)
        skyline_zipfile = SKYLINE_ADD_LIB.out.skyline_zipfile

        // import spectra into skyline file
        SKYLINE_IMPORT_MS_FILE(skyline_zipfile, ms_file_ch)

        batched_skyd_file_ch = SKYLINE_IMPORT_MS_FILE.out.skyd_file.groupTuple()
        batched_ms_file_ch = ms_file_ch.groupTuple()

        batched_input_files = batched_skyd_file_ch
            .join(batched_ms_file_ch, failOnMismatch: true, failOnDuplicate: true)
            .combine(skyline_document_name)
            .map{ batch_name, ms_files, skyd_files, document_name ->
                    [ms_files, skyd_files, get_skyline_doc_name_per_batch(document_name, batch_name)]
                }

        // Each Skyline step shares (zips) the document only when it is the last one. Between
        // adjacent steps the document is handed off as a directory, so the chromatogram
        // cache is not zipped and unzipped again at every step.
        def annotate = params.replicate_metadata != null || params.pdc.study_id != null
        def minimize = params.skyline.minimize

        SKYLINE_MERGE_RESULTS(
            skyline_zipfile,
            fasta,
            batched_input_files,
            annotate || minimize,
        )
        loose_document = SKYLINE_MERGE_RESULTS.out.loose_document
        skyline_results = SKYLINE_MERGE_RESULTS.out.final_skyline_zipfile
        skyline_results_hash = SKYLINE_MERGE_RESULTS.out.output_file_hashes

        if(annotate) {
            ANNOTATION_TSV_TO_CSV(replicate_metadata)

            // The size of the chromatogram cache sets the memory request. It is read here
            // because a process directive only sees the staged name of a directory input.
            sized_document = loose_document.map { name, directory ->
                tuple(name, directory, directory.resolve("${name}.skyd").size())
            }
            SKYLINE_ANNOTATE_DOCUMENT(sized_document,
                                      ANNOTATION_TSV_TO_CSV.out.annotation_csv,
                                      ANNOTATION_TSV_TO_CSV.out.annotation_definitions,
                                      minimize)

            loose_document = SKYLINE_ANNOTATE_DOCUMENT.out.loose_document
            skyline_results = SKYLINE_ANNOTATE_DOCUMENT.out.final_skyline_zipfile
            skyline_results_hash = SKYLINE_ANNOTATE_DOCUMENT.out.output_file_hashes
        }

        if(minimize) {
            SKYLINE_MINIMIZE_DOCUMENT(loose_document)
            skyline_results = SKYLINE_MINIMIZE_DOCUMENT.out.final_skyline_zipfile
            skyline_results_hash = SKYLINE_MINIMIZE_DOCUMENT.out.output_file_hashes
        }

    emit:
        skyline_results
        skyline_results_hash
        proteowizard_version = SKYLINE_ADD_LIB.out.version
}
