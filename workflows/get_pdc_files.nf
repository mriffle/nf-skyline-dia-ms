
include { GET_STUDY_METADATA } from "../modules/pdc.nf"
include { METADATA_TO_SKY_ANNOTATIONS } from "../modules/pdc.nf"
include { GET_FILE } from "../modules/pdc.nf"
include { MSCONVERT } from "../modules/msconvert.nf"

workflow get_pdc_study_metadata {
    emit:
        study_name
        metadata
        annotations_csv

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
}

workflow get_pdc_files {
    emit:
        study_name
        metadata
        annotations_csv
        wide_mzml_ch

    main:
        get_pdc_study_metadata()
        metadata = get_pdc_study_metadata.out.metadata
        annotations_csv = get_pdc_study_metadata.out.annotations_csv
        study_name = get_pdc_study_metadata.out.study_name

        metadata \
            | splitCsv(header:true, sep:'\t') \
            | map{row -> tuple(row.url, row.file_name, row.md5sum)} \
            | GET_FILE

        MSCONVERT(GET_FILE.out.downloaded_file,
                  params.msconvert.do_demultiplex,
                  params.msconvert.do_simasspectra)

        wide_mzml_ch = MSCONVERT.out.mzml_file
}

