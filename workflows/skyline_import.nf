// Modules
include { SKYLINE_ADD_LIB } from "../modules/skyline"

workflow skyline_import {

    take:
        skyline_template_zipfile
        fasta
        elib

    // emit:
    //     skyline_results

    main:

        // add library to skyline file
        SKYLINE_ADD_LIB(skyline_template_zipfile, fasta, elib)

        // import encyclopedia results into skyline file
        

}
