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

        spectra_dir_groups = split_spectra_dirs(spectra_dirs)
        local_matches = find_local_matches(spectra_dir_groups.local_dirs, spectra_regex)
        local_file_type = infer_local_ms_file_type(local_matches)
        expected_ms_file_type = local_file_type ?: infer_ms_file_type_from_regex(spectra_regex)

        // Fail fast for batches whose only configured spectra sources are local directories
        // that matched zero files. This is the most common misconfiguration (e.g., glob set
        // to `*.raw` against a directory of mzMLs) and we catch it before any process runs.
        check_local_only_batches_have_matches(spectra_dirs, spectra_dir_groups, local_matches, spectra_regex)

        // Find files in local directories matching spectra_regex
        if (local_matches) {
            sampled_local_files = local_matches
                .groupBy { it[0] }
                .collectMany { batch, entries ->
                    sample_list(entries.collectMany { it[1] }, n_files, params.random_file_seed)
                        .collect { matched_file -> [batch, matched_file] }
                }
            local_file_ch = sampled_local_files ? Channel.fromList(sampled_local_files) : Channel.empty()
        } else {
            local_file_ch = Channel.empty()
        }

        // List files matching spectra_regex in panorama directories
        if (spectra_dir_groups.panorama_dirs) {
            PANORAMA_GET_MS_FILE_LIST(Channel.fromList(spectra_dir_groups.panorama_dirs), spectra_regex, aws_secret_id)
            PANORAMA_GET_MS_FILE_LIST.out.ms_files
                .map{batch, file_list -> [batch, file_list.readLines().collect{ line -> line.strip() }]}
                .transpose()
                .groupTuple()
                .map{ batch, file_list ->
                    [batch, sample_list(file_list, n_files, params.random_file_seed)]
                }
                .transpose()
                .set{panorama_url_ch}
        } else {
            panorama_url_ch = Channel.empty()
        }

        // List files matching spectra_regex in panorama public directories
        if (spectra_dir_groups.panorama_public_dirs) {
            PANORAMA_PUBLIC_GET_MS_FILE_LIST(Channel.fromList(spectra_dir_groups.panorama_public_dirs), spectra_regex)
            PANORAMA_PUBLIC_GET_MS_FILE_LIST.out.ms_files
                .map{batch, file_list -> [batch, file_list.readLines().collect{ line -> line.strip() }]}
                .transpose()
                .groupTuple()
                .map{ batch, file_list ->
                    [batch, sample_list(file_list, n_files, params.random_file_seed)]
                }
                .transpose()
                .set{panorama_public_url_ch}
        } else {
            panorama_public_url_ch = Channel.empty()
        }

        panorama_url_ch
            .concat(panorama_public_url_ch)
            .concat(local_file_ch.map{ batch, file -> [batch, file.name] })
            .set{ batched_paths_ch }

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

        // Validation barrier: every expected batch must have produced at least one matched
        // file, and matched files must share a single supported MS extension. Errors raised
        // here propagate through the dataflow before downstream operators (e.g., the join
        // on Skyline-document name) can fail with confusing key-mismatch messages.
        def expected_batches = spectra_dirs.collect { it[0] } as Set
        validation_ch = batched_paths_ch
            .groupTuple()
            .toList()
            .map { entries ->
                def found_batches = entries.collect { it[0] } as Set
                def missing = expected_batches - found_batches
                if (missing) {
                    def filtered = spectra_dirs.findAll { it[0] in missing }
                    error "No spectra files matched the glob/regex:\n" +
                          format_dir_listing(filtered, spectra_regex) +
                          "\nPlease choose a file glob/regex that will match raw, mzML, or .d.zip files."
                }
                def all_files = entries.collectMany { it[1] }
                def extensions = all_files.collect { get_ms_file_type(it) }.unique()
                if (extensions.size() > 1) {
                    error "Matched more than 1 file type for:\n" +
                          format_dir_listing(spectra_dirs, spectra_regex) +
                          "\nFound extensions: [${extensions.join(', ')}]" +
                          "\nPlease choose a file glob/regex that will match exactly one MS file type."
                }
                if (!(extensions[0] in ['raw', 'mzML', 'd.zip'])) {
                    error "No MS data files found for:\n" +
                          format_dir_listing(spectra_dirs, spectra_regex) +
                          "\nFound extension: ${extensions[0]}" +
                          "\nPlease choose a file glob/regex that will match raw, mzML, or .d.zip files."
                }
                true
            }

        // Download files from panorama if applicable
        if (spectra_dir_groups.panorama_dirs) {
            PANORAMA_GET_MS_FILE(panorama_url_ch, aws_secret_id)
            panorama_file_ch = PANORAMA_GET_MS_FILE.out.panorama_file
        } else {
            panorama_file_ch = Channel.empty()
        }

        // Download files from panorama public if applicable
        if (spectra_dir_groups.panorama_public_dirs) {
            PANORAMA_PUBLIC_GET_MS_FILE(panorama_public_url_ch)
            panorama_public_file_ch = PANORAMA_PUBLIC_GET_MS_FILE.out.panorama_file
        } else {
            panorama_public_file_ch = Channel.empty()
        }

        resolved_ms_file_ch = panorama_file_ch
            .concat(panorama_public_file_ch)
            .concat(local_file_ch)

        if (expected_ms_file_type == 'mzML') {
            converted_mzml_ch = Channel.empty()
            ms_file_ch = resolved_ms_file_ch.map { batch, ms_file ->
                if (get_ms_file_type(ms_file) != 'mzML') {
                    error "Unknown file type: ${ms_file.name}"
                }
                [batch, ms_file]
            }
        } else if (expected_ms_file_type == 'raw') {
            if (params.use_vendor_raw) {
                converted_mzml_ch = Channel.empty()
                ms_file_ch = resolved_ms_file_ch.map { batch, ms_file ->
                    if (get_ms_file_type(ms_file) != 'raw') {
                        error "Unknown file type: ${ms_file.name}"
                    }
                    [batch, ms_file]
                }
            } else {
                raw_file_ch = resolved_ms_file_ch.map { batch, ms_file ->
                    if (get_ms_file_type(ms_file) != 'raw') {
                        error "Unknown file type: ${ms_file.name}"
                    }
                    [batch, ms_file]
                }
                MSCONVERT(raw_file_ch)
                converted_mzml_ch = MSCONVERT.out
                ms_file_ch = MSCONVERT.out
            }
        } else if (expected_ms_file_type == 'd.zip') {
            d_zip_file_ch = resolved_ms_file_ch.map { batch, ms_file ->
                if (get_ms_file_type(ms_file) != 'd.zip') {
                    error "Unknown file type: ${ms_file.name}"
                }
                [batch, ms_file]
            }
            UNZIP_BRUKER_D(d_zip_file_ch)
            converted_mzml_ch = Channel.empty()
            ms_file_ch = UNZIP_BRUKER_D.out
        } else {
            // Fall back to runtime branching when the selector regex does not identify a single type.
            resolved_ms_file_ch
                .branch{
                    mzml:  it[1].name.endsWith('.mzML')
                    raw:   it[1].name.endsWith('.raw')
                    d_zip: it[1].name.endsWith('.d.zip')
                    other: true
                        error "Unknown file type:" + it[1].name
                }.set{branched_ms_file_ch}

            UNZIP_BRUKER_D(branched_ms_file_ch.d_zip)

            if (params.use_vendor_raw) {
                converted_mzml_ch = Channel.empty()
                ms_file_ch = branched_ms_file_ch.raw.concat(branched_ms_file_ch.mzml, UNZIP_BRUKER_D.out)
            } else {
                MSCONVERT(branched_ms_file_ch.raw)
                converted_mzml_ch = MSCONVERT.out
                ms_file_ch = MSCONVERT.out.concat(branched_ms_file_ch.mzml, UNZIP_BRUKER_D.out)
            }
        }

        // Force ms_file_ch to wait on validation_ch so any validation error stops the
        // workflow before downstream stages can fail with confusing messages.
        ms_file_ch = ms_file_ch.combine(validation_ch).map { entry -> entry[0..-2] }

    emit:
        ms_file_ch
        converted_mzml_ch
        file_json
}

// Format a list of (batch, [dir, ...]) tuples as a multi-line listing of "<dir>/<regex>" lines,
// optionally prefixed with a batch label. Used to build user-facing error messages.
def format_dir_listing(spectra_dirs, spectra_regex) {
    return spectra_dirs.collect { batch, dirs ->
        def label = batch == null ? '' : "[batch '${batch}'] "
        dirs.collect { d -> "  ${label}${d}${d[-1] == '/' ? '' : '/'}${spectra_regex}" }.join('\n')
    }.join('\n')
}

// Synchronously fail when a batch's only spectra sources are local directories that matched
// zero files. Catches the common misconfiguration of a glob/regex that doesn't match any
// files in the supplied directory; raises before any process runs.
def check_local_only_batches_have_matches(spectra_dirs, spectra_dir_groups, local_matches, spectra_regex) {
    def panorama_batches = (spectra_dir_groups.panorama_dirs + spectra_dir_groups.panorama_public_dirs)
        .collect { it[0] } as Set
    def empty_batches = []
    local_matches.groupBy { it[0] }.each { batch, entries ->
        if (!entries.any { it[1] } && !panorama_batches.contains(batch)) {
            empty_batches << batch
        }
    }
    if (empty_batches) {
        def filtered = spectra_dirs.findAll { it[0] in empty_batches }
        error "No spectra files matched the glob/regex in local directories:\n" +
              format_dir_listing(filtered, spectra_regex) +
              "\nPlease choose a file glob/regex that will match raw, mzML, or .d.zip files."
    }
}

def is_panorama_url(url) {
    return url.startsWith(params.panorama.domain)
}

def panorama_auth_required_for_url(url) {
    return is_panorama_url(url) && !url.contains("/_webdav/Panorama%20Public/")
}

def split_spectra_dirs(spectra_dirs) {
    def split = [local_dirs: [], panorama_dirs: [], panorama_public_dirs: []]
    spectra_dirs.each { batch, dirs ->
        dirs.each { dir ->
            if (is_panorama_url(dir) && !panorama_auth_required_for_url(dir)) {
                split.panorama_public_dirs << tuple(batch, dir)
            } else if (panorama_auth_required_for_url(dir)) {
                split.panorama_dirs << tuple(batch, dir)
            } else {
                split.local_dirs << tuple(batch, dir)
            }
        }
    }
    return split
}

def find_local_matches(local_dirs, spectra_regex) {
    return local_dirs.collect { batch, dir ->
        [
            batch,
            file(dir, checkIfExists: true)
                .listFiles()
                .findAll { it.name ==~ spectra_regex }
        ]
    }
}

def infer_local_ms_file_type(local_matches) {
    def local_types = local_matches
        .collectMany { it[1] }
        .collect { get_ms_file_type(it) }
        .unique()

    if (!local_types) {
        return null
    }
    if (local_types.size() > 1) {
        error "Matched more than 1 file type in local spectra directories. Found extensions: [${local_types.join(', ')}]"
    }
    return local_types[0]
}

def infer_ms_file_type_from_regex(String file_regex) {
    if (file_regex == null) {
        return null
    }

    def normalized_regex = file_regex.trim()
    if (normalized_regex ==~ /.*\\\.d\\\.zip\$$/) {
        return 'd.zip'
    }
    if (normalized_regex ==~ /.*\\\.mzML\$$/) {
        return 'mzML'
    }
    if (normalized_regex ==~ /.*\\\.raw\$$/) {
        return 'raw'
    }
    return null
}

def get_ms_file_type(path_or_name) {
    def file_name = path_or_name instanceof File ? path_or_name.name : path_or_name.toString()
    if (file_name.endsWith('.d.zip')) {
        return 'd.zip'
    }
    if (file_name.endsWith('.mzML')) {
        return 'mzML'
    }
    if (file_name.endsWith('.raw')) {
        return 'raw'
    }
    return file_name.substring(file_name.lastIndexOf('.') + 1)
}
