// modules
include { PANORAMA_GET_FILE as PANORAMA_GET_FASTA } from "../modules/panorama"
include { PANORAMA_GET_FILE as PANORAMA_GET_SPECTRAL_LIBRARY } from "../modules/panorama"
include { PANORAMA_GET_FILE as PANORAMA_GET_SKYLINE_TEMPLATE } from "../modules/panorama"
include { PANORAMA_GET_SKYR_FILE } from "../modules/panorama"

/**
* Process a parameter variable which is specified as either a single value or List.
* If param_variable has multiple lines, each line with text is returned as an
* element in a List.
*
* @param param_variable A parameter variable which can either be a single value or List.
* @return param_variable as a List with 1 or more values.
*/
def param_to_list(param_variable) {
    if(param_variable instanceof List) {
        return param_variable
    }
    if(param_variable instanceof String) {
        // Split string by new line, remove whitespace, and skip empty lines
        return param_variable.split('\n').collect{ it.trim() }.findAll{ it }
    }
    return [param_variable]
}

workflow get_input_files {

   take:
        aws_secret_id

    main:

        // get files from Panorama as necessary
        if(params.fasta) {
            if(panorama_auth_required_for_url(params.fasta)) {
                PANORAMA_GET_FASTA(params.fasta, aws_secret_id)
                fasta = PANORAMA_GET_FASTA.out.panorama_file
            } else {
                fasta = Channel.value(file(params.fasta, checkIfExists: true))
            }
        } else {
            fasta = Channel.empty()
        }

        if(params.skyline.fasta){
            if(panorama_auth_required_for_url(params.fasta)) {
                PANORAMA_GET_FASTA(params.skyline.fasta, aws_secret_id)
                skyline_fasta = PANORAMA_GET_FASTA.out.panorama_file
            } else {
                skyline_fasta = Channel.value(file(params.skyline.fasta, checkIfExists: true))
            }
        } else {
            skyline_fasta = fasta
        }

        if(params.spectral_library) {
            if(panorama_auth_required_for_url(params.spectral_library)) {
                PANORAMA_GET_SPECTRAL_LIBRARY(params.spectral_library, aws_secret_id)
                spectral_library = PANORAMA_GET_SPECTRAL_LIBRARY.out.panorama_file
            } else {
                spectral_library = Channel.value(file(params.spectral_library, checkIfExists: true))
            }
        } else {
            spectral_library = null
        }

        if(params.skyline.template_file != null) {
            if(panorama_auth_required_for_url(params.skyline.template_file)) {
                PANORAMA_GET_SKYLINE_TEMPLATE(params.skyline.template_file, aws_secret_id)
                skyline_template_zipfile = PANORAMA_GET_SKYLINE_TEMPLATE.out.panorama_file
            } else {
                skyline_template_zipfile = file(params.skyline.template_file, checkIfExists: true)
            }
        } else {
            skyline_template_zipfile = file(params.default_skyline_template_file)
        }

        if(params.skyline.skyr_file != null) {

            // Split skyr files stored on Panorama and locally into separate channels.
            Channel.fromList(param_to_list(params.skyline.skyr_file)).branch{
                panorama_files: panorama_auth_required_for_url(it)
                local_files: true
                    return file(it, checkIfExists: true)
                }.set{skyr_paths}

            skyr_files = skyr_paths.local_files
            PANORAMA_GET_SKYR_FILE(skyr_paths.panorama_files, aws_secret_id)
            //skyr_paths.panorama_files.map { file -> tuple(file, aws_secret_id) } | PANORAMA_GET_SKYR_FILE
            skyr_files = skyr_files.concat(PANORAMA_GET_SKYR_FILE.out.panorama_file)

        } else {
            skyr_files = Channel.empty()
        }

   emit:
       fasta
       skyline_fasta
       spectral_library
       skyline_template_zipfile
       skyr_files
}

// return true if the URL requires panorama authentication (panorama public does not)
def panorama_auth_required_for_url(url) {
    return url.startsWith(params.panorama.domain) && !url.contains("/_webdav/Panorama%20Public/")
}
