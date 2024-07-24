// Modules
include { ANNOTATION_TSV_TO_CSV } from "../modules/skyline"
include { SKYLINE_MINIMIZE_DOCUMENT } from "../modules/skyline"
include { SKYLINE_ANNOTATE_DOCUMENT } from "../modules/skyline"

workflow skyline_annotate_doc {
    take:
        skyline_input
        replicate_metadata

    emit:
        skyline_results

    main:
        ANNOTATION_TSV_TO_CSV(replicate_metadata)

        if(params.skyline.minimize) {
            SKYLINE_MINIMIZE_DOCUMENT(skyline_input)
            annotate_sky_input = SKYLINE_MINIMIZE_DOCUMENT.out.final_skyline_zipfile
        } else {
            annotate_sky_input = skyline_input
        }

        SKYLINE_ANNOTATE_DOCUMENT(annotate_sky_input,
                                  ANNOTATION_TSV_TO_CSV.out.annotation_csv,
                                  ANNOTATION_TSV_TO_CSV.out.annotation_definitions)

        skyline_results = SKYLINE_ANNOTATE_DOCUMENT.out.final_skyline_zipfile
}
