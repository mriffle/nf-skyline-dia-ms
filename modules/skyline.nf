process SKYLINE_ADD_LIB {
    publishDir "${params.result_dir}/skyline/add-lib", failOnError: true, mode: 'copy'
    label 'process_medium'
    label 'error_retry'
    container 'chambm/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.22335-b595b19'

    input:
        path skyline_template_zipfile
        path fasta
        path elib

    output:
        path("results.sky.zip"), emit: skyline_zipfile

    script:
    """
    unzip ${skyline_template_zipfile}

    wine SkylineCmd \
        --in="${skyline_template_zipfile.baseName}" \
        --log-file=skyline_add_library.log \
        --import-fasta="${fasta}" \
        --add-library-path="${elib}" \
        --out="results.sky" \
        --save \
        --share-zip="results.sky.zip" \
        --share-type="complete"
    """
}

process SKYLINE_IMPORT_SPECTRA {
    publishDir "${params.result_dir}/skyline/import-spectra", failOnError: true, mode: 'copy'
    label 'process_high'
    label 'error_retry'
    container 'chambm/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.22335-b595b19'

    input:
        path skyline_zipfile
        path mzml_files

    output:
        path("final.sky.zip"), emit: final_skyline_zipfile

    script:
    import_files_params = "--import-file=${(mzml_files as List).join(' --import-file=')}"
    """
    unzip ${skyline_zipfile}

    wine SkylineCmd \
        --in="${skyline_zipfile.baseName}" \
        --import-threads=${task.cpus} \
        --log-file=skyline_add_spectra.log \
        ${import_files_params} \
        --out="final.sky" \
        --save \
        --share-zip="final.sky.zip" \
        --share-type="complete"
    """
}
