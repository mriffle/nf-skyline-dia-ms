
def sky_basename(path) {
    return path.baseName.replaceAll(/(\.zip)?\.sky$/, '')
}

process SKYLINE_ADD_LIB {
    publishDir "${params.result_dir}/skyline/add-lib", failOnError: true, mode: 'copy'
    label 'process_medium'
    label 'process_short'
    label 'error_retry'
    container 'quay.io/protio/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.24054-2352758'

    input:
        path skyline_template_zipfile
        path fasta
        path elib

    output:
        path("results.sky.zip"), emit: skyline_zipfile
        path("skyline_add_library.log"), emit: log

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

process SKYLINE_IMPORT_MZML {
    publishDir "${params.result_dir}/skyline/import-spectra", failOnError: true, mode: 'copy'
    label 'process_medium'
    label 'process_high_memory'
    label 'process_short'
    label 'error_retry'
    container 'quay.io/protio/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.24054-2352758'
    stageInMode "${workflow.profile == 'aws' ? 'symlink' : 'link'}"

    input:
        path skyline_zipfile
        path mzml_file

    output:
        path("*.skyd"), emit: skyd_file
        path("${mzml_file.baseName}.log"), emit: log_file

    script:
    """
    unzip ${skyline_zipfile}

    cp ${mzml_file} /tmp/${mzml_file}

    wine SkylineCmd \
        --in="${skyline_zipfile.baseName}" \
        --import-no-join \
        --log-file="${mzml_file.baseName}.log" \
        --import-file="/tmp/${mzml_file}" \
    """
}

process SKYLINE_MERGE_RESULTS {
    publishDir "${params.result_dir}/skyline/import-spectra", failOnError: true, mode: 'copy'
    label 'process_high'
    label 'error_retry'
    container 'quay.io/protio/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.24054-2352758'
    stageInMode "${workflow.profile == 'aws' ? 'symlink' : 'link'}"

    input:
        path skyline_zipfile
        path skyd_files
        val mzml_files
        path fasta

    output:
        path("${params.skyline.document_name}.sky.zip"), emit: final_skyline_zipfile
        path("skyline-merge.log"), emit: log
        env(sky_zip_hash), emit: file_hash

    script:
    import_files_params = "--import-file=${(mzml_files as List).collect{ "/tmp/" + file(it).name }.join(' --import-file=')}"
    protein_parsimony_args = "--import-fasta=${fasta} --associate-proteins-shared-peptides=DuplicatedBetweenProteins --associate-proteins-min-peptides=1 --associate-proteins-remove-subsets --associate-proteins-minimal-protein-list"
    if(params.skyline.group_by_gene) {
        protein_parsimony_args += '  --associate-proteins-gene-level-parsimony'
    }

    """
    unzip ${skyline_zipfile}

    cp -v ${skyd_files} /tmp/

    wine SkylineCmd \
        --in="${skyline_zipfile.baseName}" \
        --log-file="skyline-merge.log" \
        ${import_files_params} \
        ${params.skyline.protein_parisimony ? protein_parsimony_args : ''} \
        --out="${params.skyline.document_name}.sky" \
        --save \
        --share-zip="${params.skyline.document_name}.sky.zip" \
        --share-type="complete"

    sky_zip_hash=\$( md5sum ${params.skyline.document_name}.sky.zip |awk '{print \$1}' )
    """
}

process ANNOTATION_TSV_TO_CSV {
    publishDir "${params.result_dir}/skyline/annotate", failOnError: true, mode: 'copy'
    label 'process_low'
    label 'error_retry'
    container 'quay.io/mauraisa/dia_qc_report:1.15'

    input:
        path replicate_metadata

    output:
        path("sky_annotations.csv"), emit: annotation_csv
        path("sky_annotation_definitions.bat"), emit: annotation_definitions

    shell:
    """
    metadata_to_sky_annotations ${replicate_metadata}
    """

    stub:
    """
    touch sky_annotation_definitions.bat  sky_annotations.csv
    """
}

process SKYLINE_MINIMIZE_DOCUMENT {
    label 'error_retry'
    label 'process_high'
    container 'proteowizard/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.24054-2352758'

    input:
        path skyline_zipfile

    output:
        path("${sky_basename(skyline_zipfile)}_minimized.sky.zip"), emit: final_skyline_zipfile
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr
        env(sky_zip_hash), emit: file_hash

    script:
        """
        unzip ${skyline_zipfile}

        wine SkylineCmd \
            --in="${skyline_zipfile.baseName}" \
            --chromatograms-discard-unused \
            --chromatograms-limit-noise=1 \
            --out="${sky_basename(skyline_zipfile)}_minimized.sky" \
            --save \
            --share-zip="${sky_basename(skyline_zipfile)}_minimized.sky.zip" \
            --share-type="minimal" \
        > >(tee 'minimize_skyline.stdout') 2> >(tee 'minimize_skyline.stderr' >&2)

        sky_zip_hash=\$( md5sum ${sky_basename(skyline_zipfile)}_minimized.sky.zip |awk '{print \$1}' )
        """

    stub:
    """
    touch ${sky_basename(skyline_zipfile)}_minimized.sky.zip
    touch stub.stdout stub.stderr
    sky_zip_hash=\$( md5sum ${sky_basename(skyline_zipfile)}_minimized.sky.zip |awk '{print \$1}' )
    """
}

process SKYLINE_ANNOTATE_DOCUMENT {
    publishDir "${params.result_dir}/skyline/annotate", failOnError: true, mode: 'copy'
    label 'process_high_memory'
    container 'proteowizard/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.24054-2352758'

    input:
        path skyline_zipfile
        path annotation_csv
        path annotation_definitions

    output:
        path("${sky_basename(skyline_zipfile)}_annotated.sky.zip"), emit: final_skyline_zipfile
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr
        env(sky_zip_hash), emit: file_hash

    shell:
    """
    unzip ${skyline_zipfile}

    # Create Skyline batch file with annotation definitions
    echo '--in="${skyline_zipfile.baseName}"' > add_annotations.bat
    cat ${annotation_definitions} >> add_annotations.bat
    echo '--import-annotations="${annotation_csv}"' >> add_annotations.bat
    echo '--save --out="${sky_basename(skyline_zipfile)}_annotated.sky"' >> add_annotations.bat
    echo '--share-zip="${sky_basename(skyline_zipfile)}_annotated.sky.zip"' >> add_annotations.bat

    wine SkylineCmd --batch-commands=add_annotations.bat \
        > >(tee 'annotate_doc.stdout') 2> >(tee 'annotate_doc.stderr' >&2)

    sky_zip_hash=\$( md5sum ${sky_basename(skyline_zipfile)}_annotated.sky.zip |awk '{print \$1}' )
    """

    stub:
    """
    touch "${sky_basename(skyline_zipfile)}_annotated.sky.zip"
    touch stub.stdout stub.stderr
    sky_zip_hash=\$( md5sum ${sky_basename(skyline_zipfile)}_annotated.sky.zip |awk '{print \$1}' )
    """
}

process SKYLINE_RUN_REPORTS {
    publishDir "${params.result_dir}/skyline/reports", failOnError: true, mode: 'copy'
    label 'process_high'
    label 'error_retry'
    container 'quay.io/protio/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.24054-2352758'

    input:
        path skyline_zipfile
        path skyr_files

    output:
        path("*.report.tsv"), emit: skyline_report_files
        path("*.log"), emit: log

    script:
    """
    unzip ${skyline_zipfile}

    # add reports to skyline file
    for skyrfile in *.skyr; do
        wine SkylineCmd \
            --in="${skyline_zipfile.baseName}" \
            --log-file="skyline-import-\$skyrfile.log" \
            --report-add="\$skyrfile" \
            --save
    done

    # run the reports
    for xmlfile in ./*.skyr; do
        awk -F'"' '/<view name=/ { print \$2 }' "\$xmlfile" | while read reportname; do
            wine SkylineCmd \
                --in="${skyline_zipfile.baseName}" \
                --log-file="\$reportname.report-generation.log" \
                --report-name="\$reportname" \
                --report-file="./\$reportname.report.tsv" \
                --report-format="TSV" \
                --report-invariant
        done
    done
    """
}
