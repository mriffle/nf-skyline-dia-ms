// workflow to upload results to PanoramaWeb

// modules
include { UPLOAD_FILE } from "../modules/panorama"
include { IMPORT_SKYLINE } from "../modules/panorama"

workflow panorama_upload_results {

    take:
        webdav_url
        all_search_file_ch
        search_engine
        final_skyline_file
        mzml_file_ch
        fasta_file
        user_supplied_spectral_lib
        nextflow_run_details
        nextflow_config_file
        skyr_file_ch
        skyline_report_ch
        aws_secret_id

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
            .concat(all_search_file_ch.map { path -> tuple(path, upload_webdav_url + "/results/${search_engine}") })
            .concat(final_skyline_file.map { path -> tuple(path, upload_webdav_url + "/results/skyline") })
            .concat(skyr_file_ch.map { path -> tuple(path, upload_webdav_url + "/input-files") })
            .concat(skyline_report_ch.map { path -> tuple(path, upload_webdav_url + "/results/skyline_reports") })
            .set { all_file_upload_ch }

        UPLOAD_FILE(all_file_upload_ch, aws_secret_id)

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
                params.skyline.document_name,
                upload_webdav_url + "/results/skyline",
                aws_secret_id
            )
        }

    emit:
        uploads_finished
}

workflow panorama_upload_mzmls {

    take:
        webdav_url
        mzml_file_ch
        nextflow_run_details
        nextflow_config_file
        aws_secret_id

    main:

        if(!webdav_url.endsWith("/")) {
            webdav_url += "/"
        }

        upload_webdav_url = webdav_url + getUploadDirectory()

        mzml_file_ch.map { path -> tuple(path, upload_webdav_url + "/results/msconvert") }
            .concat(nextflow_run_details.map { path -> tuple(path, upload_webdav_url) })
            .concat(Channel.fromPath(nextflow_config_file).map { path -> tuple(path, upload_webdav_url) })
            .set { all_file_upload_ch }

        UPLOAD_FILE(all_file_upload_ch, aws_secret_id)
}

def getUploadDirectory() {
    return "nextflow/${getCurrentTimestamp()}/${workflow.sessionId}"
}

def getCurrentTimestamp() {
    java.time.LocalDateTime now = java.time.LocalDateTime.now()
    java.time.format.DateTimeFormatter formatter = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH-mm-ss")
    return now.format(formatter)
}