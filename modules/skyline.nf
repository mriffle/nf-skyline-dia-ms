
def sky_basename(path) {
    return path.baseName.replaceAll(/(\.zip)?\.sky$/, '').replaceAll(/_$/, '')
}

process SKYLINE_ADD_LIB {
    publishDir params.output_directories.skyline.add_lib, failOnError: true, mode: 'copy'
    cpus   4
    // 15 GB or 1.5 times the size of the spectral library, whichever is larger
    memory { Math.max(15.0, ( elib.size() / (1024 ** 3)) * 1.5 ).GB }
    time   { 2.h * task.attempt }
    label 'error_retry'
    label 'proteowizard'
    label 'SKYLINE_ADD_LIB'
    container params.images.proteowizard

    input:
        path skyline_template_zipfile
        path fasta
        path elib

    output:
        path("results.sky.zip"), emit: skyline_zipfile
        path("skyline_add_library.stdout"), emit: stdout
        path("skyline_add_library.stderr"), emit: stderr
        path("pwiz_versions.txt"), emit: version

    script:
    """
    unzip ${skyline_template_zipfile}

    wine SkylineCmd \
        --in="${skyline_template_zipfile.baseName}" \
        --import-fasta="${fasta}" \
        --add-library-path="${elib}" \
        --out="results.sky" \
        --save \
        --share-zip="results.sky.zip" \
        --share-type="complete" \
        > >(tee 'skyline_add_library.stdout') 2> >(tee 'skyline_add_library.stderr' >&2)

    # parse Skyline version info
    wine SkylineCmd --version > version.txt
    vars=(\$(cat version.txt | \
            tr -cd '\\11\\12\\15\\40-\\176' | \
            egrep -o 'Skyline.*' | \
            sed -E "s/(Skyline[-a-z]*) \\((.*)\\) ([.0-9]+) \\(([A-Za-z0-9]{7})\\)/\\1 \\3 \\4/"))
    skyline_build="\${vars[0]}"
    skyline_version="\${vars[1]}"
    skyline_commit="\${vars[2]}"

    # parse msconvert info
    msconvert_version=\$(cat version.txt | \
                        tr -cd '\\11\\12\\15\\40-\\176' | \
                        egrep -o 'Proteo[a-zA-Z0-9\\. ]+' | \
                        egrep -o [0-9].*)

    echo "skyline_build=\${skyline_build}" > pwiz_versions.txt
    echo "skyline_version=\${skyline_version}" >> pwiz_versions.txt
    echo "skyline_commit=\${skyline_commit}" >> pwiz_versions.txt
    echo "msconvert_version=\${msconvert_version}" >> pwiz_versions.txt
    """

    stub:
    """
    touch "results.sky.zip"
    touch "skyline_add_library.stderr" "skyline_add_library.stdout"

    # parse Skyline version info
    wine SkylineCmd --version > version.txt
    vars=(\$(cat version.txt | \
            tr -cd '\\11\\12\\15\\40-\\176' | \
            egrep -o 'Skyline.*' | \
            sed -E "s/(Skyline[-a-z]*) \\((.*)\\) ([.0-9]+) \\(([A-Za-z0-9]{7})\\)/\\1 \\3 \\4/"))
    skyline_build="\${vars[0]}"
    skyline_version="\${vars[1]}"
    skyline_commit="\${vars[2]}"

    # parse msconvert info
    msconvert_version=\$(cat version.txt | \
                        tr -cd '\\11\\12\\15\\40-\\176' | \
                        egrep -o 'Proteo[a-zA-Z0-9\\. ]+' | \
                        egrep -o [0-9].*)

    echo "skyline_build=\${skyline_build}" > pwiz_versions.txt
    echo "skyline_version=\${skyline_version}" >> pwiz_versions.txt
    echo "skyline_commit=\${skyline_commit}" >> pwiz_versions.txt
    echo "msconvert_version=\${msconvert_version}" >> pwiz_versions.txt
    """
}

process SKYLINE_IMPORT_MS_FILE {
    publishDir params.output_directories.skyline.import_spectra, pattern: '*.std[oe][ur][tr]', failOnError: true, mode: 'copy'
    cpus   8
    // 8 GB or 1.5 times the size of the skyline zip file and ms_file, whichever is larger
    memory { Math.max(8.0, ((skyline_zipfile.size() + ms_file.size()) / (1024 ** 3)) * 1.5 ).GB }
    time   { 4.h * task.attempt }
    label 'error_retry'
    label 'proteowizard'
    cache 'lenient'
    label 'SKYLINE_IMPORT_MS_FILE'
    container params.images.proteowizard
    stageInMode "${params.skyline.use_hardlinks && executor != 'awsbatch' ? 'link' : 'symlink'}"

    input:
        path skyline_zipfile
        tuple val(batch_name), path(ms_file)

    output:
        tuple val(batch_name), path("*.skyd"), emit: skyd_file
        path("${ms_file.baseName}.stdout"), emit: stdout
        path("${ms_file.baseName}.stderr"), emit: stderr

    script:
    """
    unzip ${skyline_zipfile}

    cp -vraL ${ms_file} /tmp/

    wine SkylineCmd \
        --in="${skyline_zipfile.baseName}" \
        --import-no-join \
        --import-file="/tmp/${ms_file.name}" \
        > >(tee '${ms_file.baseName}.stdout') 2> >(tee '${ms_file.baseName}.stderr' >&2)
    """

    stub:
    """
    touch "${ms_file.baseName}.stdout" "${ms_file.baseName}.stderr" "${ms_file.baseName}.skyd"
    """
}

process SKYLINE_MERGE_RESULTS {
    publishDir params.output_directories.skyline.import_spectra, enabled: params.replicate_metadata == null && params.pdc.study_id == null, failOnError: true, mode: 'copy'
    cpus   32
    // 8 GB or 1.5 times the total size of all the skyd files, whichever is larger
    memory { Math.max(8.0, ((skyd_files*.size().sum()) / (1024 ** 3)) * 1.5).GB }
    time   { 8.h * task.attempt }
    label 'error_retry'
    label 'proteowizard'
    cache 'lenient'
    label 'SKYLINE_MERGE_RESULTS'
    container params.images.proteowizard
    stageInMode "${params.skyline.use_hardlinks && executor != 'awsbatch' ? 'link' : 'symlink'}"

    input:
        path skyline_zipfile
        path fasta
        tuple path(skyd_files), val(ms_files), val(skyline_document_name)

    output:
        path("*.sky.zip"), emit: final_skyline_zipfile
        path("skyline-merge.stdout"), emit: stdout
        path("skyline-merge.stderr"), emit: stderr
        path('output_file_hashes.txt'), emit: output_file_hashes

    script:

    import_files_params = "--import-file=\"${(ms_files as List).collect{ "/tmp/" + file(it).name }.join('\" --import-file=\"')}\""
    protein_parsimony_args = "--import-fasta=${fasta} --associate-proteins-shared-peptides=DuplicatedBetweenProteins --associate-proteins-min-peptides=1 --associate-proteins-remove-subsets --associate-proteins-minimal-protein-list"
    if(params.skyline.group_by_gene) {
        protein_parsimony_args += ' --associate-proteins-gene-level-parsimony'
    }

    """
    unzip ${skyline_zipfile}

    cp -vaL ${skyd_files} /tmp/

    wine SkylineCmd \
        --in="${skyline_zipfile.baseName}" \
        ${import_files_params} \
        ${params.skyline.protein_parsimony ? protein_parsimony_args : ''} \
        --out="${skyline_document_name}.sky" \
        --save \
        --share-zip="${skyline_document_name}.sky.zip" \
        --share-type="complete" \
        > >(tee 'skyline-merge.stdout') 2> >(tee 'skyline-merge.stderr' >&2)

    md5sum ${skyline_document_name}.sky.zip | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > output_file_hashes.txt
    """

    stub:
    """
    touch "${skyline_document_name}.sky.zip"
    touch "skyline-merge.stderr" "skyline-merge.stdout"
    md5sum ${skyline_document_name}.sky.zip | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > output_file_hashes.txt
    """
}

process ANNOTATION_TSV_TO_CSV {
    publishDir params.output_directories.skyline.import_spectra, failOnError: true, mode: 'copy'
    label 'process_low'
    container params.images.qc_pipeline

    input:
        path replicate_metadata

    output:
        path("${replicate_metadata.baseName}.annotations.csv"), emit: annotation_csv
        path("${replicate_metadata.baseName}.definitions.bat"), emit: annotation_definitions

    script:
    """
    dia_qc metadata_convert -o skyline ${replicate_metadata}
    """

    stub:
    """
    touch ${replicate_metadata.baseName}.definitions.bat ${replicate_metadata.baseName}.annotations.csv
    """
}

process SKYLINE_MINIMIZE_DOCUMENT {
    publishDir params.output_directories.skyline.minimize, failOnError: true, mode: 'copy'
    label 'error_retry'
    label 'process_high'
    label 'proteowizard'
    container params.images.proteowizard

    input:
        path skyline_zipfile

    output:
        path("${sky_basename(skyline_zipfile)}_minimized.sky.zip"), emit: final_skyline_zipfile
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr
        path('output_file_hashes.txt'), emit: output_file_hashes

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

        md5sum ${sky_basename(skyline_zipfile)}_minimized.sky.zip | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > output_file_hashes.txt
        """

    stub:
    """
    touch ${sky_basename(skyline_zipfile)}_minimized.sky.zip
    touch stub.stdout stub.stderr
    md5sum ${sky_basename(skyline_zipfile)}_minimized.sky.zip | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > output_file_hashes.txt
    """
}

process SKYLINE_ANNOTATE_DOCUMENT {
    publishDir params.output_directories.skyline.import_spectra, failOnError: true, mode: 'copy'
    cpus   8
    memory { Math.max(8.0, (skyline_zipfile.size() / (1024 ** 3)) * 1.5).GB }
    time   { 4.h * task.attempt }
    label 'proteowizard'
    label 'SKYLINE_ANNOTATE_DOCUMENT'
    container params.images.proteowizard

    input:
        path skyline_zipfile
        path annotation_csv
        path annotation_definitions

    output:
        path("${sky_basename(skyline_zipfile)}_annotated.sky.zip"), emit: final_skyline_zipfile
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr
        path('output_file_hashes.txt'), emit: output_file_hashes

    script:
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

    md5sum ${sky_basename(skyline_zipfile)}_annotated.sky.zip | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > output_file_hashes.txt
    """

    stub:
    """
    touch "${sky_basename(skyline_zipfile)}_annotated.sky.zip"
    touch stub.stdout stub.stderr
    md5sum ${sky_basename(skyline_zipfile)}_annotated.sky.zip | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > output_file_hashes.txt
    """
}

process SKYLINE_RUN_REPORTS {
    publishDir params.output_directories.skyline.reports, failOnError: true, mode: 'copy'
    cpus   8
    memory { Math.max(8.0, (skyline_zipfile.size() / (1024 ** 3)) * 1.5).GB }
    time   { 4.h * task.attempt }
    label 'process_high'
    label 'error_retry'
    label 'proteowizard'
    label 'SKYLINE_RUN_REPORTS'
    container params.images.proteowizard

    input:
        tuple val(batch), path(skyline_zipfile)
        path skyr_files

    output:
        tuple val(batch), path("*.report.tsv"), emit: skyline_report_files
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
    """
    unzip ${skyline_zipfile}

    # generate skyline batch file to export reports
    echo '--in="${skyline_zipfile.baseName}"' > export_reports.bat

    for skyrfile in ./*.skyr; do
        # Add report to document
        echo "--report-add=\\"\${skyrfile}\\" --report-conflict-resolution=overwrite" >> export_reports.bat

        # Export report
        awk -F'"' '/<view name=/ { print \$2 }' "\$skyrfile" | while read reportname; do
            echo "--report-name=\\"\${reportname}\\" \
                  --report-file=\\"${batch == null ? '' : batch + '_'}\${reportname}.report.tsv\\" \
                  --report-format=TSV --report-invariant" \
                  >> export_reports.bat
        done
    done

    # Run batch commands
    wine SkylineCmd --batch-commands=export_reports.bat \
        > >(tee 'export_reports.stdout') 2> >(tee 'export_reports.stderr' >&2)
    """

    stub:
    """
    for skyrfile in ./*.skyr; do
        awk -F'"' '/<view name=/ { print \$2 }' "\$skyrfile" | while read reportname; do
            touch ${batch == null ? '' : batch + '_'}\${reportname}.report.tsv
        done
    done

    if [ \$(ls *.report.tsv|wc -l) -eq 0 ] ; then
        touch stub.report.tsv
    fi

    touch stub.stdout stub.stderr
    """
}