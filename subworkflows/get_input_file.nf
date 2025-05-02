
// modules
include { PANORAMA_GET_FILE } from "../modules/panorama"

include { panorama_auth_required_for_url } from "./get_input_files"

workflow get_input_file {
    take:
        file_path
        aws_secret_id

    main:
        if(panorama_auth_required_for_url(file_path)) {
            PANORAMA_GET_FILE(file_path, aws_secret_id)
            file = PANORAMA_GET_FILE.out.panorama_file
        } else {
            file = Channel.value(file(params.spectral_library, checkIfExists: true))
        }

    emit:
        file
}