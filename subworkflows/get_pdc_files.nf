include { GET_STUDY_METADATA } from "../modules/pdc.nf"
include { METADATA_TO_SKY_ANNOTATIONS } from "../modules/pdc.nf"
include { GET_FILE } from "../modules/pdc.nf"
include { MSCONVERT_MULTI_BATCH as MSCONVERT } from "../modules/msconvert.nf"
include { UNZIP_DIRECTORY as UNZIP_BRUKER_D } from "../modules/msconvert.nf"

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
        file_entries = tsv_entries.mix(json_entries)

        GET_FILE(file_entries)
        all_paths_ch = GET_FILE.out.downloaded_file

        // Parse batch file if provided
        def batch_map = params.pdc.batch_file != null ? parse_batch_file(params.pdc.batch_file) : null

        // Map files to [batch_name, file] tuples
        all_paths_ch
            .map{ file ->
                def batch_name = null
                if (batch_map != null) {
                    batch_name = batch_map[file.name]
                    if (batch_name == null) {
                        error "PDC file '${file.name}' is not present in batch file '${params.pdc.batch_file}'."
                    }
                }
                [batch_name, file]
            }
            .branch{
                raw:   it[1].name.endsWith('.raw')
                d_zip: it[1].name.endsWith('.d.zip')
                other: true
                    error "Unknown file type: " + it[1].name
            }
            .set{ ms_file_ch }

        // Validate that all files in the batch file are present in the downloaded files
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

        // Convert raw files if applicable
        if (params.use_vendor_raw) {
            converted_mzml_ch = Channel.empty()
            wide_ms_file_ch = ms_file_ch.raw.concat(UNZIP_BRUKER_D.out)
        } else {
            MSCONVERT(ms_file_ch.raw)
            converted_mzml_ch = MSCONVERT.out
            wide_ms_file_ch = MSCONVERT.out.concat(UNZIP_BRUKER_D.out)
        }

    emit:
        study_name = get_pdc_study_metadata.out.study_name
        metadata = metadata_ch
        annotations_csv = get_pdc_study_metadata.out.annotations_csv
        wide_ms_file_ch
        converted_mzml_ch
}
