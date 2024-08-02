// modules
include { PANORAMA_GET_FILE as PANORAMA_GET_FASTA } from "../modules/panorama"
include { PANORAMA_GET_FILE as PANORAMA_GET_SPECTRAL_LIBRARY } from "../modules/panorama"
include { PANORAMA_GET_FILE as PANORAMA_GET_SKYLINE_TEMPLATE } from "../modules/panorama"
include { PANORAMA_GET_SKYR_FILE } from "../modules/panorama"
include { PANORAMA_GET_FILE as PANORAMA_GET_METADATA } from "../modules/panorama"
include { MAKE_EMPTY_FILE as METADATA_PLACEHOLDER } from "../modules/qc_report"

/**
* Process a parameter variable which specified as either a single value or List.
*
* @param param_variable A parameter variable which can either be a single value or List.
* @return param_variable A List with 1 or more values.
*/
def param_to_list(param_variable) {
    if(param_variable instanceof List) {
        return param_variable
    }
    return [param_variable]
}

workflow get_input_files {

   emit:
       fasta
       spectral_library
       skyline_template_zipfile
       skyr_files
       replicate_metadata

    main:

        // get files from Panorama as necessary
        if(params.fasta.startsWith("https://")) {
            PANORAMA_GET_FASTA(params.fasta)
            fasta = PANORAMA_GET_FASTA.out.panorama_file
        } else {
            fasta = file(params.fasta, checkIfExists: true)
        }

        if(params.spectral_library) {
            if(params.spectral_library.startsWith("https://")) {
                PANORAMA_GET_SPECTRAL_LIBRARY(params.spectral_library)
                spectral_library = PANORAMA_GET_SPECTRAL_LIBRARY.out.panorama_file
            } else {
                spectral_library = file(params.spectral_library, checkIfExists: true)
            }
        } else {
            spectral_library = null
        }

        if(params.skyline.template_file != null) {
            if(params.skyline.template_file.startsWith("https://")) {
                PANORAMA_GET_SKYLINE_TEMPLATE(params.skyline.template_file)
                skyline_template_zipfile = PANORAMA_GET_SKYLINE_TEMPLATE.out.panorama_file
            } else {
                skyline_template_zipfile = file(params.skyline.template_file, checkIfExists: true)
            }
        } else {
            skyline_template_zipfile = file(params.default_skyline_template_file)
        }

        if(params.skyline.skyr_file != null) {

            // Split skyr files stored on Panorama and locally into separate channels.
            skyr_paths = param_to_list(params.skyline.skyr_file)
            panorama_skyr_files = skyr_paths.findAll{
                it.startsWith("https://panoramaweb.org")
            }
            local_skyr_files = skyr_paths.findAll{
                !it.startsWith("https://panoramaweb.org")
            }

            // convert to files, check all exist
            skyr_files = Channel.fromList(local_skyr_files).map {
                path -> file(path, checkIfExists: true)
            }

            if(panorama_skyr_files.size() > 0) {
                Channel.fromList(panorama_skyr_files) | PANORAMA_GET_SKYR_FILE
                skyr_files = skyr_files.concat(PANORAMA_GET_SKYR_FILE.out.panorama_file)
            }
        } else {
            skyr_files = Channel.empty()
        }

        if(params.replicate_metadata != null) {
            if(params.replicate_metadata.trim().startsWith("https://panoramaweb.org")) {
                PANORAMA_GET_METADATA(params.replicate_metadata)
                replicate_metadata = PANORAMA_GET_METADATA.out.panorama_file
            } else {
                replicate_metadata = params.replicate_metadata
            }
        } else {
            METADATA_PLACEHOLDER('EMPTY')
            replicate_metadata = METADATA_PLACEHOLDER.out
        }
}
