
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
            metadata = Channel.fromPath(file(params.pdc.metadata_tsv, checkIfExists: true))
            METADATA_TO_SKY_ANNOTATIONS(metadata)
            annotations_csv = METADATA_TO_SKY_ANNOTATIONS.out
            study_name = params.pdc.study_name
        }

    emit:
        study_name
        metadata
        annotations_csv
}

workflow get_pdc_files {
    main:
        get_pdc_study_metadata()
        metadata = get_pdc_study_metadata.out.metadata

        metadata \
            | splitJson() \
            | map{ row -> tuple(row['url'], row['file_name'], row['md5sum'], row['file_size']) } \
            | GET_FILE

        GET_FILE.out.downloaded_file
            .tap{ all_paths_ch }
            .map{ file -> [null, file] }
            .branch{
                raw:   it[1].name.endsWith('.raw')
                d_zip: it[1].name.endsWith('.d.zip')
                other: true
                    error "Unknown file type: " + it[1].name
            }
            .set{ ms_file_ch }

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
        metadata
        annotations_csv = get_pdc_study_metadata.out.annotations_csv
        wide_ms_file_ch
        converted_mzml_ch
}
