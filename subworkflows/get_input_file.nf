
// modules
include { PANORAMA_GET_FILE } from "../modules/panorama"

include { panorama_auth_required_for_url } from "./get_input_files"
include { resolve_user_path } from "../modules/utils.nf"

workflow get_input_file {
    take:
        file_path
        aws_secret_id
        param_label

    main:
        if(panorama_auth_required_for_url(file_path)) {
            PANORAMA_GET_FILE(file_path, aws_secret_id)
            file = PANORAMA_GET_FILE.out.panorama_file
        } else {
            file = Channel.value(resolve_user_path(file_path, param_label))
        }

    emit:
        file
}