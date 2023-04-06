// modules
include { PANORAMA_GET_FASTA } from "../modules/panorama"
include { PANORAMA_GET_SPECTRAL_LIBRARY } from "../modules/panorama"

workflow get_input_files {

   emit:
       fasta
       spectral_library
       skyline_template_zipfile

    main:

        // get files from Panorama as necessary
        if(params.fasta.startsWith("https://")) {
            PANORAMA_GET_FASTA(params.fasta)
            fasta = PANORAMA_GET_FASTA.out.panorama_file
        } else {
            fasta = file(params.fasta, checkIfExists: true)
        }

        if(params.spectral_library.startsWith("https://")) {
            PANORAMA_GET_SPECTRAL_LIBRARY(params.spectral_library)
            spectral_library = PANORAMA_GET_SPECTRAL_LIBRARY.out.panorama_file
        } else {
            spectral_library = file(params.spectral_library, checkIfExists: true)
        }

        if(params.skyline_template_file != null) {
            if(params.skyline_template_file.startsWith("https://")) {
                PANORAMA_GET_SKYLINE_TEMPLATE(params.skyline_template_file)
                skyline_template_zipfile = PANORAMA_GET_SKYLINE_TEMPLATE.out.panorama_file
            } else {
                skyline_template_zipfile = file(params.skyline_template_file, checkIfExists: true)
            }
        } else {
            skyline_template_zipfile = file(params.default_skyline_template_file)
        }

}
