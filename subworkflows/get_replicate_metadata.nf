
include { VALIDATE_LOCAL_METADATA } from "../modules/qc_report"
include { VALIDATE_PANORAMA_METADATA } from "../modules/qc_report"
include { VALIDATE_PANORAMA_PUBLIC_METADATA } from "../modules/qc_report"
include { MAKE_EMPTY_FILE as METADATA_PLACEHOLDER } from "../modules/qc_report"

include { panorama_auth_required_for_url } from "./get_input_files"

workflow get_replicate_metadata {
    take:
        quant_spectra_file_json
        chrom_lib_file_json
        aws_secret_id

    main:
        if(params.replicate_metadata != null) {
            if(panorama_auth_required_for_url(params.replicate_metadata.trim())) {
                VALIDATE_PANORAMA_METADATA(
                    quant_spectra_file_json, chrom_lib_file_json,
                    params.replicate_metadata, aws_secret_id
                )
                validated_metadata = VALIDATE_PANORAMA_METADATA.out.replicate_metadata
            } else if (params.replicate_metadata.startsWith(params.panorama.domain)) {
                VALIDATE_PANORAMA_PUBLIC_METADATA(
                    quant_spectra_file_json, chrom_lib_file_json,
                    params.replicate_metadata
                )
                validated_metadata = VALIDATE_PANORAMA_PUBLIC_METADATA.out.replicate_metadata
            } else {
                VALIDATE_LOCAL_METADATA(
                    quant_spectra_file_json, chrom_lib_file_json,
                    file(params.replicate_metadata, checkIfExists: true)
                )
                validated_metadata = VALIDATE_LOCAL_METADATA.out.replicate_metadata
            }
        } else if(params.pdc.study_id != null) {
            validated_metadata = null
        } else {
            METADATA_PLACEHOLDER('EMPTY')
            validated_metadata = METADATA_PLACEHOLDER.out
        }

    emit:
        validated_metadata
}
