
include { get_total_file_sizes } from './utils.nf'

def sky_basename(path) {
    return path.baseName.replaceAll(/(\.zip)?\.sky$/, '').replaceAll(/_$/, '')
}

process SKYLINE_ADD_LIB {
    publishDir params.output_directories.skyline.add_lib, failOnError: true, mode: 'copy'
    cpus   8
    memory { Math.max(8.0, ( elib.size() / (1024 ** 3)) * 10 ).GB }
    time   { 4.h * task.attempt }
    label 'error_retry'
    label 'proteowizard'
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

    # Handle case where the skyline_template_zipfile basename does not match the .sky file inside.
    # This can happen when a .sky.zip file shared to Panorama from the Skyline GUI
    mapfile -t sky_files < <(unzip -Z1 "${skyline_template_zipfile}" | grep -E '\\.sky\$')
    if [ "\${#sky_files[@]}" -ne 1 ]; then
        echo "Error: expected exactly one .sky in ${skyline_template_zipfile.name}, found \${#sky_files[@]}" >&2
        printf '%s\n' "\${sky_files[@]}" >&2
        exit 1
    fi
    skyfile="\${sky_files[0]}"

    wine SkylineCmd \
        --in="\$skyfile" \
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

    echo "skyline_build=stub"     >  pwiz_versions.txt
    echo "skyline_version=stub"   >> pwiz_versions.txt
    echo "skyline_commit=stub"    >> pwiz_versions.txt
    echo "msconvert_version=stub" >> pwiz_versions.txt
    """
}

process SKYLINE_IMPORT_MS_FILE {
    publishDir params.output_directories.skyline.import_spectra, pattern: '*.std[oe][ur][tr]', failOnError: true, mode: 'copy'
    cpus   8
    memory { Math.max(16.0, ((skyline_zipfile.size() + ms_file.size()) / (1024 ** 3)) * 6 ).GB }
    time   { 2.h * task.attempt }
    label 'error_retry'
    label 'proteowizard'
    cache 'lenient'
    container params.images.proteowizard
    stageInMode {
        def hardlink_ok = params.skyline.use_hardlinks && task.executor != 'awsbatch'
        if (!hardlink_ok) return 'symlink'
        ms_file.name.endsWith('.d') ? 'symlink' : 'link'
    }

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
    // The merged document is the final one only when neither the annotate nor the minimize
    // step follows. Annotation runs when replicate metadata or PDC annotations are available;
    // this mirrors the branch in subworkflows/skyline_import.nf.
    // Publish merge logs for every run and the archive hash whenever merge produces a ZIP.
    publishDir params.output_directories.skyline.final_documents, pattern: '*.sky.zip', enabled: params.replicate_metadata == null && params.pdc.study_id == null && !params.skyline.minimize, failOnError: true, mode: 'copy'
    publishDir params.output_directories.skyline.import_spectra, pattern: '*.{stdout,stderr,txt}', failOnError: true, mode: 'copy'
    cpus   32
    memory {
        def bytes   = get_total_file_sizes(skyd_files)
        // println "DEBUG: bytes = ${bytes}"

        def gib     = bytes / (1024 ** 3)
        def scaled  = gib * 6
        def wineOh  = 8

        def totalGb = (scaled + wineOh).toInteger()
        // println "DEBUG: gib=${gib}, scaled=${scaled}, totalGb=${totalGb}"

        Math.max(16, totalGb).GB
    }
    time   { 8.h * task.attempt }
    label 'error_retry'
    label 'proteowizard'
    cache 'lenient'
    container params.images.proteowizard
    stageInMode "${params.skyline.use_hardlinks && task.executor != 'awsbatch' ? 'link' : 'symlink'}"

    input:
        path skyline_zipfile
        path fasta
        tuple path(skyd_files), val(ms_files), val(skyline_document_name)
        val(annotate)

    output:
        path("${skyline_document_name}.sky.zip"), optional: true, emit: final_skyline_zipfile
        tuple val(skyline_document_name), path('skyline-document', type: 'dir'), optional: true, emit: loose_document
        path("${skyline_document_name}.skyline-merge.stdout"), emit: stdout
        path("${skyline_document_name}.skyline-merge.stderr"), emit: stderr
        path("${skyline_document_name}.output_file_hashes.txt"), optional: true, emit: output_file_hashes

    script:

    import_files_params = "--import-file=\"${(ms_files as List).collect{ "/tmp/" + file(it).name }.join('\" --import-file=\"')}\""
    protein_parsimony_args = "--associate-proteins-shared-peptides=DuplicatedBetweenProteins --associate-proteins-min-peptides=1 --associate-proteins-remove-subsets --associate-proteins-minimal-protein-list"
    if(params.skyline.group_by_gene) {
        protein_parsimony_args += ' --associate-proteins-gene-level-parsimony'
    }

    // Keep the extracted libraries and other Skyline sidecars next to the merged document.
    def document_directory = annotate ? 'skyline-document/' : ''
    def share_zip = annotate ? '' : "--share-zip=\"${skyline_document_name}.sky.zip\" --share-type=complete"

    """
    ${annotate ? 'mkdir skyline-document' : ''}
    unzip "${skyline_zipfile}" ${annotate ? '-d skyline-document' : ''}

    cp -vaL ${skyd_files} /tmp/

    wine SkylineCmd \
        --in="${document_directory}${skyline_zipfile.baseName}" \
        ${import_files_params} \
        --import-fasta=${fasta} \
        ${params.skyline.protein_parsimony ? protein_parsimony_args : ''} \
        ${params.skyline.group_proteins ? '--associate-proteins-group-proteins' : ''} \
        --out="${document_directory}${skyline_document_name}.sky" \
        --save \
        ${share_zip} \\
        > >(tee '${skyline_document_name}.skyline-merge.stdout') 2> >(tee '${skyline_document_name}.skyline-merge.stderr' >&2)

    if [ "${annotate}" = true ]; then
        test -s "${document_directory}${skyline_document_name}.sky"
        test -s "${document_directory}${skyline_document_name}.skyd"
    else
        test -s "${skyline_document_name}.sky.zip"
        md5sum "${skyline_document_name}.sky.zip" | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > "${skyline_document_name}.output_file_hashes.txt"
    fi
    """

    stub:
    """
    touch "${skyline_document_name}.skyline-merge.stderr" "${skyline_document_name}.skyline-merge.stdout"
    if [ "${annotate}" = true ]; then
        mkdir skyline-document
        touch "skyline-document/${skyline_document_name}.sky" "skyline-document/${skyline_document_name}.skyd"
    else
        touch "${skyline_document_name}.sky.zip"
        md5sum "${skyline_document_name}.sky.zip" | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > "${skyline_document_name}.output_file_hashes.txt"
    fi
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
    publishDir params.output_directories.skyline.final_documents, pattern: '*.sky.zip', failOnError: true, mode: 'copy'
    publishDir params.output_directories.skyline.minimize, pattern: '*.{stdout,stderr,txt}', failOnError: true, mode: 'copy'
    label 'error_retry'
    label 'process_high'
    label 'proteowizard'
    container params.images.proteowizard

    input:
        path skyline_zipfile

    output:
        path("${sky_basename(skyline_zipfile)}_minimized.sky.zip"), emit: final_skyline_zipfile
        path("${sky_basename(skyline_zipfile)}_minimized.minimize_skyline.stdout"), emit: stdout
        path("${sky_basename(skyline_zipfile)}_minimized.minimize_skyline.stderr"), emit: stderr
        path("${sky_basename(skyline_zipfile)}_minimized.output_file_hashes.txt"), emit: output_file_hashes

    script:
        // Every published file is named after the document it describes. In batch mode this
        // process runs once per batch and all of them publish into the same directory, so
        // fixed file names would overwrite each other.
        out_basename = "${sky_basename(skyline_zipfile)}_minimized"

        """
        unzip ${skyline_zipfile}

        wine SkylineCmd \
            --in="${skyline_zipfile.baseName}" \
            --chromatograms-discard-unused \
            --chromatograms-limit-noise=1 \
            --out="${out_basename}.sky" \
            --save \
            --share-zip="${out_basename}.sky.zip" \
            --share-type="minimal" \
        > >(tee '${out_basename}.minimize_skyline.stdout') 2> >(tee '${out_basename}.minimize_skyline.stderr' >&2)

        md5sum "${out_basename}.sky.zip" | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > "${out_basename}.output_file_hashes.txt"
        """

    stub:
        out_basename = "${sky_basename(skyline_zipfile)}_minimized"

        """
        touch "${out_basename}.sky.zip"
        touch "${out_basename}.minimize_skyline.stdout" "${out_basename}.minimize_skyline.stderr"
        md5sum "${out_basename}.sky.zip" | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > "${out_basename}.output_file_hashes.txt"
        """
}

def annotated_basename(document_basename) {
    return document_basename.replaceAll(/_$/, '') + '_annotated'
}

process SKYLINE_ANNOTATE_DOCUMENT {
    publishDir params.output_directories.skyline.final_documents, pattern: '*.sky.zip', enabled: !params.skyline.minimize, failOnError: true, mode: 'copy'
    publishDir params.output_directories.skyline.import_spectra, pattern: '*.{stdout,stderr,txt}', failOnError: true, mode: 'copy'
    cpus   8
    memory { Math.max(12.0, (chromatogram_bytes / (1024 ** 3)) * 2).GB }
    time   { 4.h * task.attempt }
    label 'proteowizard'
    container params.images.proteowizard

    input:
        tuple val(document_basename), path(skyline_document), val(chromatogram_bytes)
        path annotation_csv
        path annotation_definitions

    output:
        path("${annotated_basename(document_basename)}.sky.zip"), emit: final_skyline_zipfile
        path("${annotated_basename(document_basename)}.annotate_doc.stdout"), emit: stdout
        path("${annotated_basename(document_basename)}.annotate_doc.stderr"), emit: stderr
        path("${annotated_basename(document_basename)}.output_file_hashes.txt"), emit: output_file_hashes

    script:
    // Every published file is named after the document it describes. In batch mode this
    // process runs once per batch and all of them publish into the same directory, so
    // fixed file names would overwrite each other.
    out_basename = "${annotated_basename(document_basename)}"

    """
    # Create Skyline batch file with annotation definitions
    echo '--in="${skyline_document}/${document_basename}.sky"' > add_annotations.bat
    cat ${annotation_definitions} >> add_annotations.bat
    echo '--import-annotations="${annotation_csv}"' >> add_annotations.bat
    echo '--save --out="${out_basename}.sky"' >> add_annotations.bat
    echo '--share-zip="${out_basename}.sky.zip"' >> add_annotations.bat

    wine SkylineCmd --batch-commands=add_annotations.bat \
        > >(tee '${out_basename}.annotate_doc.stdout') 2> >(tee '${out_basename}.annotate_doc.stderr' >&2)

    md5sum "${out_basename}.sky.zip" | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > "${out_basename}.output_file_hashes.txt"
    """

    stub:
    out_basename = "${annotated_basename(document_basename)}"

    """
    touch "${out_basename}.sky.zip"
    touch "${out_basename}.annotate_doc.stdout" "${out_basename}.annotate_doc.stderr"
    md5sum "${out_basename}.sky.zip" | sed -E 's/([a-f0-9]{32}) [ \\*](.*)/\\1\\t\\2/' > "${out_basename}.output_file_hashes.txt"
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
