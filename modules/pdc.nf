
def format_client_args(var) {
    ret = (var == null ? "" : var)
    return ret
}

process GET_STUDY_METADATA {
    publishDir "${params.result_dir}/pdc", failOnError: true, mode: 'copy'
    errorStrategy 'retry'
    maxRetries 5
    label 'process_low_constant'
    container params.images.pdc_client

    input:
        val pdc_study_id

    output:
        path('study_metadata.tsv'), emit: metadata
        path('study_metadata_annotations.csv'), emit: skyline_annotations
        env(study_id), emit: study_id
        env(study_name), emit: study_name
        path('pdc_client_version.txt'), emit: version

    shell:
    n_files_arg = params.pdc.n_raw_files == null ? "" : "--nFiles ${params.pdc.n_raw_files}"
    pdc_client_args = params.pdc.client_args == null ? "" : params.pdc.client_args

    '''
    study_id=$(PDC_client studyID !{pdc_client_args} !{pdc_study_id} | tee study_id.txt)
    study_name=$(PDC_client studyName --normalize !{pdc_client_args} ${study_id} | tee study_name.txt)
    PDC_client metadata !{pdc_client_args} -f tsv !{n_files_arg} --skylineAnnotations ${study_id}

    echo "pdc_client_git_repo='$GIT_REPO - $GIT_BRANCH [$GIT_SHORT_HASH]'" > pdc_client_version.txt
    '''
}

process METADATA_TO_SKY_ANNOTATIONS {
    label 'process_low_constant'
    container params.images.pdc_client

    input:
        path pdc_study_metadata

    output:
        path('skyline_annotations.csv'), emit: skyline_annotations

    shell:
    '''
    PDC_client metadataToSky !{pdc_study_metadata}
    '''
}

process GET_FILE {
    storeDir "${params.panorama_cache_directory}"
    cpus 1
    memory 8.GB
    time 2.h
    maxForks 10
    errorStrategy { sleep(Math.pow(2, task.attempt) * 200 as long); return 'retry' }
    maxRetries 3
    container params.images.pdc_client

    input:
        tuple val(url), val(file_name), val(md5)

    output:
        path(file_name), emit: downloaded_file

    shell:
    '''
    PDC_client file -o '!{file_name}' -m '!{md5}' '!{url}'
    '''

    stub:
    """
    touch ${file_name}
    """
}
