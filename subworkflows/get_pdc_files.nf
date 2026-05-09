include { GET_STUDY_METADATA } from "../modules/pdc.nf"
include { METADATA_TO_SKY_ANNOTATIONS } from "../modules/pdc.nf"
include { GET_FILE } from "../modules/pdc.nf"
include { MSCONVERT_MULTI_BATCH as MSCONVERT } from "../modules/msconvert.nf"
include { UNZIP_DIRECTORY as UNZIP_BRUKER_D } from "../modules/msconvert.nf"
include { param_to_list } from "../modules/utils.nf"

workflow get_pdc_study_metadata {
    main:
        if(params.pdc.metadata_tsv == null) {
            GET_STUDY_METADATA(params.pdc.study_id)
            metadata = GET_STUDY_METADATA.out.metadata
            annotations_csv = GET_STUDY_METADATA.out.skyline_annotations
            study_name = GET_STUDY_METADATA.out.study_name
        } else {
            metadata_file = file(params.pdc.metadata_tsv, checkIfExists: true)
            metadata = Channel.fromPath(metadata_file)
            METADATA_TO_SKY_ANNOTATIONS(metadata_file)
            annotations_csv = METADATA_TO_SKY_ANNOTATIONS.out.skyline_annotations
            study_name = params.pdc.study_name == null ? params.pdc.study_id : params.pdc.study_name
        }

    emit:
        study_name
        metadata
        annotations_csv
}

// Parse a batch file (TSV with columns: file_name, batch) into a map of filename -> batch_name
def parse_batch_file(batch_file_path) {
    def batch_map = [:]
    def f = file(batch_file_path, checkIfExists: true)
    def lines = f.readLines()
    if (lines.size() < 2) {
        error "Batch file '${batch_file_path}' must have a header row and at least one data row."
    }
    def header = lines[0].split('\t')
    def file_name_idx = header.findIndexOf { it.trim() == 'file_name' }
    def batch_idx = header.findIndexOf { it.trim() == 'batch' }
    if (file_name_idx < 0 || batch_idx < 0) {
        error "Batch file '${batch_file_path}' must have 'file_name' and 'batch' columns."
    }
    lines[1..-1].each { line ->
        def fields = line.split('\t')
        def fname = fields[file_name_idx].trim()
        def batch = fields[batch_idx].trim()
        if (fname && batch) {
            batch_map[fname] = batch
        }
    }
    return batch_map
}

// Random sample helper. Defined at top-level (not inside workflow `main:`) so the strict
// Nextflow 24 parser does not reject `def x = list.findAll{}` patterns inside a workflow scope.
def sample_entries(list, n, long seed) {
    if (n == null || n >= list.size()) {
        return list
    }
    def random = new Random(seed)
    def shuffled = list.toList()
    Collections.shuffle(shuffled, random)
    return shuffled.take(n)
}

// Stem of a PDC file_name. Used to match a converted/unzipped output (whose name has the
// .raw, .mzML, or .d.zip suffix stripped) back to its original PDC entry by role.
def pdc_file_stem(name) {
    if (name.endsWith('.d.zip')) return name[0..-7]
    if (name.endsWith('.mzML'))  return name[0..-6]
    if (name.endsWith('.raw'))   return name[0..-5]
    return name
}

// Validate the PDC metadata file list against the requested partitioning. Called from a
// subscribe block (matches the existing batch_map / extension validation pattern).
// Errors raised here halt the workflow; the message surfaces in .nextflow.log under
// "Caused by:" and Nextflow's top-level shows InvocationTargetException — same UX as
// the other channel-closure-raised errors in this subworkflow.
def validate_pdc_partition(entries) {
    if (entries.size() == 0) {
        error "No files returned by PDC_client metadata for study '${params.pdc.study_id}'."
    }
    def total = entries.size()

    def n_quant = params.pdc.n_raw_files == null ? total : (params.pdc.n_raw_files as int)
    if (n_quant > total) {
        error "params.pdc.n_raw_files (${n_quant}) exceeds the total number of files in PDC study '${params.pdc.study_id}' (${total})."
    }

    if (params.carafe.pdc_files != null) {
        def requested = param_to_list(params.carafe.pdc_files) as Set
        def all_names = entries.collect { it[1] } as Set
        def missing = requested - all_names
        if (missing) {
            error "params.carafe.pdc_files entries not found in PDC study '${params.pdc.study_id}': ${missing.toList().sort().join(', ')}"
        }
    } else if (params.carafe.pdc_n_files != null) {
        def n_carafe = params.carafe.pdc_n_files as int
        if (n_carafe > total) {
            error "params.carafe.pdc_n_files (${n_carafe}) exceeds the total number of files in PDC study '${params.pdc.study_id}' (${total})."
        }
        // n_carafe <= n_quant is enforced upstream in main.nf carafe_enabled().
    }
}

// Partition the full PDC study file list into a quant set (size = pdc.n_raw_files, or all
// files when null) and an optional Carafe set (named via carafe.pdc_files, or randomly
// sampled via carafe.pdc_n_files). Returns a list of [role, url, file_name, md5, file_size]
// tuples to download. role ∈ {'quant', 'carafe', 'both'}. Validation lives in
// validate_pdc_partition; this function assumes inputs are valid.
def partition_pdc_entries(entries) {
    def total = entries.size()
    def n_quant = params.pdc.n_raw_files == null ? total : (params.pdc.n_raw_files as int)
    def quant_entries = entries.take(n_quant)
    def quant_names = quant_entries.collect { it[1] } as Set

    def carafe_names = [] as Set
    if (params.carafe.pdc_files != null) {
        carafe_names = param_to_list(params.carafe.pdc_files) as Set
    } else if (params.carafe.pdc_n_files != null) {
        def sampled = sample_entries(quant_entries, params.carafe.pdc_n_files as int, params.random_file_seed as long)
        carafe_names = sampled.collect { it[1] } as Set
    }

    def needed_names = (quant_names + carafe_names) as Set
    def to_download = entries.findAll { it[1] in needed_names }

    return to_download.collect { entry ->
        def in_q = entry[1] in quant_names
        def in_c = entry[1] in carafe_names
        def role = (in_q && in_c) ? 'both' : (in_q ? 'quant' : 'carafe')
        [role, entry[0], entry[1], entry[2], entry[3]]
    }
}

workflow get_pdc_files {
    main:
        get_pdc_study_metadata()
        def metadata_ch = get_pdc_study_metadata.out.metadata

        // Handle both tsv and json metadata files
        def meta_split = metadata_ch.branch {
            tsv:   it.name.toLowerCase().endsWith('.tsv')
            json:  it.name.toLowerCase().endsWith('.json')
            other: true
                error "Unsupported metadata file type: ${it.name} (must be .tsv or .json)"
        }
        tsv_entries = meta_split.tsv
            .splitCsv(header:true, sep:'\t')
            .map { row ->
                tuple(row.url, row.file_name, row.md5sum, row.file_size)
            }
        json_entries = meta_split.json
            .splitJson()
            .map { row ->
               tuple(row['url'], row['file_name'], row['md5sum'], row['file_size'])
            }

        // Full PDC study file list -> role-tagged download set. validate_pdc_partition
        // surfaces user-facing errors via subscribe (matches the existing pattern used
        // for batch_map and extension validation downstream); partition_pdc_entries
        // assumes valid inputs and produces the role-tagged tuples.
        all_entries_ch = tsv_entries.mix(json_entries).toList()
        all_entries_ch.subscribe { entries -> validate_pdc_partition(entries) }
        tagged_entries = all_entries_ch.flatMap { entries -> partition_pdc_entries(entries) }

        // Per-file (file_name, role) and (stem, role) lookups, used to re-tag downloaded
        // files and to split the post-conversion channel into quant and Carafe subsets.
        name_role_ch = tagged_entries.map { role, url, name, md5, size -> tuple(name, role) }
        stem_role_ch = tagged_entries.map { role, url, name, md5, size -> tuple(pdc_file_stem(name), role) }

        // Strip role for the GET_FILE input. GET_FILE's per-file PDC_client invocation is
        // unchanged; we just hand it the partitioned union of quant + Carafe-only files.
        GET_FILE(tagged_entries.map { role, url, name, md5, size -> tuple(url, name, md5, size) })
        all_paths_ch = GET_FILE.out.downloaded_file

        // Parse batch file if provided
        def batch_map = params.pdc.batch_file != null ? parse_batch_file(params.pdc.batch_file) : null

        // Tag downloaded files with role. Apply batch_map only to files that participate
        // in the main quant set; Carafe-only files (role 'carafe') don't require a batch
        // entry in the user's batch file.
        labeled_files_ch = all_paths_ch
            .map { f -> tuple(f.name, f) }
            .join(name_role_ch)
            .map { name, file, role ->
                def batch_name = null
                if (batch_map != null && (role == 'quant' || role == 'both')) {
                    batch_name = batch_map[name]
                    if (batch_name == null) {
                        error "PDC file '${name}' is not present in batch file '${params.pdc.batch_file}'."
                    }
                }
                [batch_name, file]
            }

        labeled_files_ch
            .branch{
                raw:   it[1].name.endsWith('.raw')
                d_zip: it[1].name.endsWith('.d.zip')
                other: true
                    error "Unknown file type: " + it[1].name
            }
            .set{ ms_file_ch }

        // Validate that all files in the batch file are present in the downloaded files.
        // batch_map only describes the main quant set; the union download set is a superset,
        // so this check still holds.
        if (batch_map != null) {
            all_paths_ch.collect().subscribe{ fileList ->
                def downloaded_names = fileList.collect { it.name } as Set
                def batch_file_names = batch_map.keySet()
                def missing_from_downloads = batch_file_names - downloaded_names
                if (missing_from_downloads) {
                    error "The following files are in the batch file but were not downloaded from PDC: " +
                          missing_from_downloads.join(", ")
                }
            }
        }

        all_paths_ch.collect().subscribe{ fileList ->
            // Check that we have exactly 1 MS file extension
            def extensions = fileList.collect { it.name.substring(it.name.lastIndexOf('.') + 1) }.unique()
            if (extensions.size() == 0) {
                error "No MS files found in study:\n" + params.pdc.study_id
            }
            if (extensions.size() > 1) {
                error "Matched more than 1 MS file type for study:\n" + params.pdc.study_id +
                      "\nFound extensions: [" + extensions.join(", ") + "]"
            }
        }

        UNZIP_BRUKER_D(ms_file_ch.d_zip)

        // Convert/unzip the union; we'll split into quant and Carafe channels post-conversion.
        def msconvert_out_ch = Channel.empty()
        if (params.use_vendor_raw) {
            full_converted_ch = ms_file_ch.raw.concat(UNZIP_BRUKER_D.out)
        } else {
            MSCONVERT(ms_file_ch.raw)
            msconvert_out_ch = MSCONVERT.out
            full_converted_ch = MSCONVERT.out.concat(UNZIP_BRUKER_D.out)
        }

        // Split converted files into the main quant channel (kept as (batch, file) tuples
        // for downstream Skyline import) and a flat Carafe channel (consumed directly by
        // the Carafe workflow's branch operator).
        tagged_converted_ch = full_converted_ch
            .map { batch, file -> tuple(file.baseName, batch, file) }
            .join(stem_role_ch)

        wide_ms_file_ch = tagged_converted_ch
            .filter { stem, batch, file, role -> role == 'quant' || role == 'both' }
            .map { stem, batch, file, role -> tuple(batch, file) }

        carafe_pdc_ms_file_ch = tagged_converted_ch
            .filter { stem, batch, file, role -> role == 'carafe' || role == 'both' }
            .map { stem, batch, file, role -> file }

        // converted_mzml_ch feeds the main run-details / Panorama upload paths. Restrict
        // to the quant subset so Carafe-only PDC files don't appear in the main analysis
        // manifest. Stays empty when use_vendor_raw is true (no msconvert ran).
        converted_mzml_ch = msconvert_out_ch
            .map { batch, file -> tuple(file.baseName, batch, file) }
            .join(stem_role_ch)
            .filter { stem, batch, file, role -> role == 'quant' || role == 'both' }
            .map { stem, batch, file, role -> tuple(batch, file) }

    emit:
        study_name = get_pdc_study_metadata.out.study_name
        metadata = metadata_ch
        annotations_csv = get_pdc_study_metadata.out.annotations_csv
        wide_ms_file_ch
        converted_mzml_ch
        carafe_pdc_ms_file_ch
}
