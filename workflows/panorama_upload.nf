// workflow to upload results to PanoramaWeb

import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

// modules
include { UPLOAD_FILE } from "../modules/panorama"
include { IMPORT_SKYLINE } from "../modules/panorama"

workflow panorama_upload_results {

    take:
        webdav_url
        all_elib_files
        all_diann_file_ch
        final_skyline_file
        mzml_file_ch
        fasta_file
        user_supplied_spectral_lib
        nextflow_run_details
        nextflow_config_file
        skyr_file_ch
        skyline_report_ch
    
    emit:
        uploads_finished
    
    main:

        if(!webdav_url.endsWith("/")) {
            webdav_url += "/"
        }

        upload_webdav_url = webdav_url + getUploadDirectory()

        mzml_file_ch.map { path -> tuple(path, upload_webdav_url + "/results/msconvert") }
            .concat(nextflow_run_details.map { path -> tuple(path, upload_webdav_url) })
            .concat(Channel.fromPath(nextflow_config_file).map { path -> tuple(path, upload_webdav_url) })
            .concat(fasta_file.map { path -> tuple(path, upload_webdav_url + "/input-files") })
            .concat(user_supplied_spectral_lib.map { path -> tuple(path, upload_webdav_url + "/input-files") })
            .concat(all_elib_files.map { path -> tuple(path, upload_webdav_url + "/results/encyclopedia") })
            .concat(all_diann_file_ch.map { path -> tuple(path, upload_webdav_url + "/results/diann") })
            .concat(final_skyline_file.map { path -> tuple(path, upload_webdav_url + "/results/skyline") })
            .concat(skyr_file_ch.map { path -> tuple(path, upload_webdav_url + "/input-files") })
            .concat(skyline_report_ch.map { path -> tuple(path, upload_webdav_url + "/results/skyline_reports") })
            .set { all_file_upload_ch }

        UPLOAD_FILE(all_file_upload_ch)

        // will be used for state dependency -- pass this channel into any process that requires
        // all file uploads to be complete
        uploads_finished = UPLOAD_FILE.out.stdout
            .collect()
            .map { true }  // will only contain a single true value after all uploads are finished
                           // passing uploads_finished into a subsequent process will ensure that
                           // process will only run after all uploads are finished.

        // import Skyline document if requested
        if(params.panorama.import_skyline) {
            IMPORT_SKYLINE(
                uploads_finished,
                params.skyline_document_name,
                upload_webdav_url + "/results/skyline"
            )
        }
}

workflow panorama_upload_mzmls {

    take:
        webdav_url
        mzml_file_ch
        nextflow_run_details
        nextflow_config_file
    
    main:

        if(!webdav_url.endsWith("/")) {
            webdav_url += "/"
        }

        upload_webdav_url = webdav_url + getUploadDirectory()

        mzml_file_ch.map { path -> tuple(path, upload_webdav_url + "/results/msconvert") }
            .concat(nextflow_run_details.map { path -> tuple(path, upload_webdav_url) })
            .concat(Channel.fromPath(nextflow_config_file).map { path -> tuple(path, upload_webdav_url) })
            .set { all_file_upload_ch }

        UPLOAD_FILE(all_file_upload_ch)
}

def getUploadDirectory() {
    directory = "nextflow/${getCurrentTimestamp()}/${workflow.sessionId}"
}

def getCurrentTimestamp() {
    LocalDateTime now = LocalDateTime.now()
    DateTimeFormatter formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH-mm-ss")
    return now.format(formatter)
}