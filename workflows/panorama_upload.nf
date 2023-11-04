// workflow to upload results to PanoramaWeb

import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

// modules
include { UPLOAD_FILE } from "../modules/panorama"

workflow panorama_upload_results {

    take:
        webdav_url
        all_elib_files
        final_skyline_file
        mzml_file_ch
        fasta_file
        user_supplied_spectral_lib
        nextflow_run_details
        nextflow_config_file
        skyr_file_ch
        skyline_report_ch
    
    main:

        upload_webdav_url = webdav_url + "/" + get_upload_directory()

        mzml_file_ch.map { path -> tuple(path, upload_webdav_url + "/results/msconvert") }
            .concat(nextflow_run_details.map { path -> tuple(path, upload_webdav_url) })
            .concat(Channel.fromPath(nextflow_config_file).map { path -> tuple(path, upload_webdav_url) })
            .concat(fasta_file.map { path -> tuple(path, upload_webdav_url + "/input-files") })
            .concat(user_supplied_spectral_lib.map { path -> tuple(path, upload_webdav_url + "/input-files") })
            .concat(all_elib_files.map { path -> tuple(path, upload_webdav_url + "/results/encyclopedia") })
            .concat(final_skyline_file.map { path -> tuple(path, upload_webdav_url + "/results/skyline") })
            .concat(skyr_file_ch.map { path -> tuple(path, upload_webdav_url + "/input-files") })
            .concat(skyline_report_ch.map { path -> tuple(path, upload_webdav_url + "/results/skyline_reports") })
            .set { all_file_upload_ch }

        UPLOAD_FILE(all_file_upload_ch)
}

workflow panorama_upload_mzmls {

    take:
        webdav_url
        mzml_file_ch
        nextflow_run_details
        nextflow_config_file
    
    main:

        upload_webdav_url = webdav_url + "/" + get_upload_directory()

        mzml_file_ch.map { path -> tuple(path, upload_webdav_url + "/results/msconvert") }
            .concat(nextflow_run_details.map { path -> tuple(path, upload_webdav_url) })
            .concat(Channel.fromPath(nextflow_config_file).map { path -> tuple(path, upload_webdav_url) })
            .set { all_file_upload_ch }

        UPLOAD_FILE(all_file_upload_ch)
}


def get_upload_directory() {
    directory = "nextflow/${getCurrentTimestamp()}/${workflow.sessionId}"
}

def getCurrentTimestamp() {
    LocalDateTime now = LocalDateTime.now()
    DateTimeFormatter formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH-mm-ss")
    return now.format(formatter)
}