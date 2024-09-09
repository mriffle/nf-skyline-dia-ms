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
        elib
        wide_mzml_file_ch
        replicate_metadata

    emit:
        skyline_results
        proteowizard_version

    main:

        // add library to skyline file
        SKYLINE_ADD_LIB(skyline_template_zipfile, fasta, elib)
        skyline_zipfile = SKYLINE_ADD_LIB.out.skyline_zipfile

        // import spectra into skyline file
        SKYLINE_IMPORT_MZML(skyline_zipfile, wide_mzml_file_ch)

        // merge sky files
        SKYLINE_MERGE_RESULTS(
            skyline_zipfile,
            SKYLINE_IMPORT_MZML.out.skyd_file.collect(),
            wide_mzml_file_ch.collect(),
            fasta
        )

        if(params.replicate_metadata != null || params.pdc.study_id != null) {
            ANNOTATION_TSV_TO_CSV(replicate_metadata)

            SKYLINE_ANNOTATE_DOCUMENT(SKYLINE_MERGE_RESULTS.out.final_skyline_zipfile,
                                      ANNOTATION_TSV_TO_CSV.out.annotation_csv,
                                      ANNOTATION_TSV_TO_CSV.out.annotation_definitions)

            sky_minimize_input = SKYLINE_ANNOTATE_DOCUMENT.out.final_skyline_zipfile
        } else {
            sky_minimize_input = SKYLINE_MERGE_RESULTS.out.final_skyline_zipfile
        }

        if(params.skyline.minimize) {
            SKYLINE_MINIMIZE_DOCUMENT(sky_minimize_input)
            skyline_results = SKYLINE_MINIMIZE_DOCUMENT.out.final_skyline_zipfile
        } else {
            skyline_results = sky_minimize_input
        }

        proteowizard_version = SKYLINE_ADD_LIB.out.version
}
