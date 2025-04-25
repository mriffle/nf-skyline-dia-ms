// modules
include { PANORAMA_GET_MS_FILE } from "../modules/panorama"
include { PANORAMA_GET_MS_FILE_LIST } from "../modules/panorama"
include { PANORAMA_PUBLIC_GET_MS_FILE } from "../modules/panorama"
include { PANORAMA_PUBLIC_GET_MS_FILE_LIST } from "../modules/panorama"
include { MSCONVERT_MULTI_BATCH as MSCONVERT } from "../modules/msconvert"

// useful functions and variables
include { param_to_list } from "./get_input_files"
include { escapeRegex } from "../modules/panorama"

/**
 * Randomly sample a list and return a list with n elements.
 */
def sample_list(list, n, long seed) {
    if (n == null || n >= list.size()) {
        return list
    }
    def random = new Random(seed)
    def shuffled = list.toList()
    Collections.shuffle(shuffled, random)
    return shuffled.take(n)
}

workflow get_ms_files {
    take:
        spectra_dir
        spectra_glob
        n_files
        aws_secret_id

    main:

        if (spectra_dir instanceof Map) {
            spectra_dirs = spectra_dir.collect{ k, v -> tuple(k, param_to_list(v))}
        } else {
            spectra_dirs = [tuple(null, param_to_list(spectra_dir))]
        }

        // Parse spectra_dir parameter and split local and panorama directories
        spectra_dirs_ch = Channel.fromList(spectra_dirs)
            .transpose()
            .branch{ batch, dir ->
                panorama_public_dirs: is_panorama_url(dir) && !panorama_auth_required_for_url(dir)
                panorama_dirs: panorama_auth_required_for_url(dir)
                local_dirs: true
            }

        // Find files in local directories matching spectra_glob
        String spectra_regex = '^' + escapeRegex(spectra_glob).replaceAll('\\*', '.*') + '$'
        local_file_ch = spectra_dirs_ch.local_dirs
            .map{ batch, dir ->
                [batch, file(dir, checkIfExists: true)
                    .listFiles()
                    .findAll{ it ==~ spectra_regex }]
            }.transpose()
            .groupTuple()
            .map{ batch, file_list ->
                [batch, sample_list(file_list, n_files, params.random_file_seed)]
            }
            .transpose()

        // List files matching spectra_glob in panorama directories
        PANORAMA_GET_MS_FILE_LIST(spectra_dirs_ch.panorama_dirs, spectra_glob, aws_secret_id)
        PANORAMA_GET_MS_FILE_LIST.out.ms_files
            .map{batch, file_list -> [batch, file_list.readLines().collect{ line -> line.strip() }]}
            .transpose()
            .groupTuple()
            .map{ batch, file_list ->
                [batch, sample_list(file_list, n_files, params.random_file_seed)]
            }
            .transpose()
            .set{panorama_url_ch}

        // List files matching spectra_glob in panorama public directories
        PANORAMA_PUBLIC_GET_MS_FILE_LIST(spectra_dirs_ch.panorama_public_dirs, spectra_glob)
        PANORAMA_PUBLIC_GET_MS_FILE_LIST.out.ms_files
            .map{batch, file_list -> [batch, file_list.readLines().collect{ line -> line.strip() }]}
            .transpose()
            .groupTuple()
            .map{ batch, file_list ->
                [batch, sample_list(file_list, n_files, params.random_file_seed)]
            }
            .transpose()
            .set{panorama_public_url_ch}

        // make sure that all files have the same extension
        all_paths_ch = panorama_url_ch.map{ it -> it[1] }
            .concat(
                panorama_public_url_ch.map{ it -> it[1] },
                local_file_ch.map{
                    it -> it[1].name
                }
            )

        all_paths_ch.collect().subscribe{ fileList ->
            def directories = spectra_dirs.collect{
                it -> it[1].collect{
                        dir -> "${dir}${dir[-1] == '/' ? '' : '/' }${spectra_glob}"
                    }.join('\n')
                }.join('\n')

            // Check that we have exactly 1 MS file extension
            def extensions = fileList.collect { it.substring(it.lastIndexOf('.') + 1) }.unique()
            if (extensions.size() == 0) {
                error "No files matches for:\n" + directories +
                      "\nPlease choose a file glob that will match raw or mzML files."
            }
            if (extensions.size() > 1) {
                error "Matched more than 1 file type for:\n" + directories +
                      "\nFound extensions: [" + extensions.join(", ") + "]" +
                      "\nPlease choose a file glob that will only match one type of file."
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
                mzml: it[1].name.endsWith('.mzML')
                raw: it[1].name.endsWith('.raw')
                other: true
                    error "Unknown file type:" + it[1].name
            }.set{ms_file_ch}

        // Convert raw files if applicable
        MSCONVERT(ms_file_ch.raw)

        converted_mzml_ch = MSCONVERT.out
        ms_file_ch = MSCONVERT.out.concat(ms_file_ch.mzml)

    emit:
        ms_file_ch
        converted_mzml_ch
}

def is_panorama_url(url) {
    return url.startsWith(params.panorama.domain)
}

def panorama_auth_required_for_url(url) {
    return is_panorama_url(url) && !url.contains("/_webdav/Panorama%20Public/")
}
