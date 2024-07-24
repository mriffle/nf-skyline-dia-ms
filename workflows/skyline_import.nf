// Modules
include { SKYLINE_ADD_LIB } from "../modules/skyline"
include { SKYLINE_IMPORT_MZML } from "../modules/skyline"
include { SKYLINE_MERGE_RESULTS } from "../modules/skyline"

workflow skyline_import {

    take:
        skyline_template_zipfile
        fasta
        elib
        wide_mzml_file_ch

    emit:
        skyline_results

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

        skyline_results = SKYLINE_MERGE_RESULTS.out.final_skyline_zipfile
}
