// modules
include { PANORAMA_GET_MS_FILE } from "../modules/panorama"
include { PANORAMA_GET_MS_FILE_LIST } from "../modules/panorama"
include { PANORAMA_PUBLIC_GET_MS_FILE } from "../modules/panorama"
include { PANORAMA_PUBLIC_GET_MS_FILE_LIST } from "../modules/panorama"
include { MSCONVERT_MULTI_BATCH as MSCONVERT } from "../modules/msconvert"
include { UNZIP_DIRECTORY as UNZIP_BRUKER_D } from "../modules/msconvert"

// useful functions and variables
include { param_to_list } from "../modules/utils.nf"

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
        spectra_regex
        n_files
        aws_secret_id

    main:

        if (spectra_dir instanceof Map) {
            spectra_dirs = spectra_dir.collect{ k, v -> tuple(k, param_to_list(v))}
            multi_batch = true
        } else {
            spectra_dirs = [tuple(null, param_to_list(spectra_dir))]
            multi_batch = false
        }

        // Parse spectra_dir parameter and split local and panorama directories
        spectra_dirs_ch = Channel.fromList(spectra_dirs)
            .transpose()
            .branch{ _, dir ->
                panorama_public_dirs: is_panorama_url(dir) && !panorama_auth_required_for_url(dir)
                panorama_dirs: panorama_auth_required_for_url(dir)
                local_dirs: true
            }

        // Find files in local directories matching spectra_regex
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

        // List files matching spectra_regex in panorama directories
        PANORAMA_GET_MS_FILE_LIST(spectra_dirs_ch.panorama_dirs, spectra_regex, aws_secret_id)
        PANORAMA_GET_MS_FILE_LIST.out.ms_files
            .map{batch, file_list -> [batch, file_list.readLines().collect{ line -> line.strip() }]}
            .transpose()
            .groupTuple()
            .map{ batch, file_list ->
                [batch, sample_list(file_list, n_files, params.random_file_seed)]
            }
            .transpose()
            .set{panorama_url_ch}

        // List files matching spectra_regex in panorama public directories
        PANORAMA_PUBLIC_GET_MS_FILE_LIST(spectra_dirs_ch.panorama_public_dirs, spectra_regex)
        PANORAMA_PUBLIC_GET_MS_FILE_LIST.out.ms_files
            .map{batch, file_list -> [batch, file_list.readLines().collect{ line -> line.strip() }]}
            .transpose()
            .groupTuple()
            .map{ batch, file_list ->
                [batch, sample_list(file_list, n_files, params.random_file_seed)]
            }
            .transpose()
            .set{panorama_public_url_ch}

        panorama_url_ch
            .concat(panorama_public_url_ch)
            .concat(local_file_ch.map{ batch, file -> [batch, file.name] })
            .tap{ batched_paths_ch }
            .map{ _, path -> path }
            .set{ all_paths_ch }

        // Collapse list of files into a JSON string
        // The string is passed to qc_report.VALIDATE_METADATA
        if (multi_batch) {
            file_json = batched_paths_ch
                .groupTuple()
                .map{ batch, file_list -> [ batch, file_list.sort() ] }
                .toList()
                .map{ items ->
                    def sorted = items.sort()
                    def parts = sorted.collect{ batch, files ->
                        def names = files.collect{ f -> "\"${new File(f).name}\"" }.join(", ")
                        "\"${batch}\":[${names}]"
                    }
                    return "{${ parts.join(", ") }}"
                }
        } else {
            file_json = batched_paths_ch
                .map{ _, path -> new File(path).name }
                .toSortedList()
                .map{ list ->
                    def quoted = list.collect{ "\"${it}\"" }.join(", ")
                    "[${quoted}]"
                }
        }

        // make sure that all files have the same extension
        all_paths_ch.collect().subscribe{ fileList ->
            def directories = spectra_dirs.collect{
                it -> it[1].collect{
                        dir -> "${dir}${dir[-1] == '/' ? '' : '/' }${spectra_regex}"
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
                mzml:  it[1].name.endsWith('.mzML')
                raw:   it[1].name.endsWith('.raw')
                d_zip: it[1].name.endsWith('.d.zip')
                other: true
                    error "Unknown file type:" + it[1].name
            }.set{ms_file_ch}

        UNZIP_BRUKER_D(ms_file_ch.d_zip)

        // Convert raw files if applicable
        if (params.use_vendor_raw) {
            converted_mzml_ch = Channel.empty()
            ms_file_ch = ms_file_ch.raw.concat(ms_file_ch.mzml, UNZIP_BRUKER_D.out)
        } else {
            MSCONVERT(ms_file_ch.raw)
            converted_mzml_ch = MSCONVERT.out
            ms_file_ch = MSCONVERT.out.concat(ms_file_ch.mzml, UNZIP_BRUKER_D.out)
        }

    emit:
        ms_file_ch
        converted_mzml_ch
        file_json
}

def is_panorama_url(url) {
    return url.startsWith(params.panorama.domain)
}

def panorama_auth_required_for_url(url) {
    return is_panorama_url(url) && !url.contains("/_webdav/Panorama%20Public/")
}
