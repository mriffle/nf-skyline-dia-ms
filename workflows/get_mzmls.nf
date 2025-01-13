// modules
include { PANORAMA_GET_MS_FILE } from "../modules/panorama"
include { PANORAMA_GET_MS_FILE_LIST } from "../modules/panorama"
include { PANORAMA_PUBLIC_GET_MS_FILE } from "../modules/panorama"
include { PANORAMA_PUBLIC_GET_MS_FILE_LIST } from "../modules/panorama"
include { MSCONVERT } from "../modules/msconvert"

// useful functions and variables
include { param_to_list } from "./get_input_files"
include { escapeRegex } from "../modules/panorama"

workflow get_mzmls {
    take:
        spectra_dir
        spectra_glob
        aws_secret_id

    emit:
       mzml_ch

    main:

        // Parse spectra_dir parameter and split local and panorama directories
        spectra_dirs = param_to_list(spectra_dir)
        spectra_dirs_ch = Channel.fromList(spectra_dirs)
            .branch{
                panorama_public_dirs: is_panorama_url(it) && !panorama_auth_required_for_url(it)
                panorama_dirs: panorama_auth_required_for_url(it)
                local_dirs: true
            }

        // Find files in local directories matching spectra_glob
        String spectra_regex = '^' + escapeRegex(spectra_glob).replaceAll('\\*', '.*') + '$'
        local_file_ch = spectra_dirs_ch.local_dirs
            .map{ it ->
                file(it, checkIfExists: true)
                    .listFiles()
                    .findAll{ it ==~ spectra_regex }
            }.flatten()

        // List files matching spectra_glob in panorama directories
        PANORAMA_GET_MS_FILE_LIST(spectra_dirs_ch.panorama_dirs, spectra_glob, aws_secret_id)
        PANORAMA_GET_MS_FILE_LIST.out.ms_files
            .map{it -> it.readLines().collect{ line -> line.strip() }}
            .flatten()
            .set{panorama_url_ch}

        // List files matching spectra_glob in panorama public directories
        PANORAMA_PUBLIC_GET_MS_FILE_LIST(spectra_dirs_ch.panorama_public_dirs, spectra_glob)
        PANORAMA_PUBLIC_GET_MS_FILE_LIST.out.ms_files
            .map{it -> it.readLines().collect{ line -> line.strip() }}
            .flatten()
            .set{panorama_public_url_ch}

        // make sure that all files have the same extension
        all_paths_ch = panorama_url_ch.concat(
            panorama_public_url_ch,
            local_file_ch.map{
                it -> it.name
            }
        )
        all_paths_ch.collect().subscribe{ fileList ->
            extensions = fileList.collect { it.substring(it.lastIndexOf('.') + 1) }.unique()

            // Check that we have exactly 1 MS file extension
            directories = spectra_dirs.collect{ it -> "${it}${it[-1] == '/' ? '' : '/' }${spectra_glob}" }.join('\n')
            if (extensions.size() == 0) {
                error "No files matches for:\n" + directories +
                      "\nPlease choose a file glob that will match raw or mzML files."
            }
            if (extensions.size() > 1) {
                error "Matched more than 1 file type for:\n" + directories +
                      "\nPlease choose a file glob that will only match one type of file"
            }

            if(!extensions in ['raw', 'mzML']) {
                error "No MS data files found for:\n" + directories
            }
        }

        // Download files from panorama if applicable
        PANORAMA_GET_MS_FILE(panorama_url_ch, aws_secret_id)

        // Download files from panorama public if applicable
        PANORAMA_PUBLIC_GET_MS_FILE(panorama_public_url_ch)

        PANORAMA_GET_MS_FILE.out.panorama_file
            .concat(PANORAMA_PUBLIC_GET_MS_FILE.out.panorama_file)
            .concat(local_file_ch)
            .branch{
                mzml: it.name.endsWith('.mzML')
                raw: it.name.endsWith('.raw')
                other: true
                    error "Unknown file type:" + it.name
            }.set{ms_file_ch}

        // Convert raw files if applicable
        MSCONVERT(ms_file_ch.raw)

        mzml_ch = MSCONVERT.out.concat(ms_file_ch.mzml)
}

def is_panorama_url(url) {
    return url.startsWith(params.panorama.domain)
}

def panorama_auth_required_for_url(url) {
    return is_panorama_url(url) && !url.contains("/_webdav/Panorama%20Public/")
}
