
/**
 * Generate the msconvert command based off user defined parameters.
 */
def msconvert_command() {
    return """
    wine msconvert -v --zlib --mzML --64 \
        --ignoreUnknownInstrumentError --filter "peakPicking true 1-" \
        ${params.msconvert.do_demultiplex ? '--filter "demultiplex optimization=overlap_only"' : ''} \
        ${params.msconvert.do_simasspectra ? '--simAsSpectra' : ''} \
        ${params.msconvert.mz_shift_ppm == null ? '' : '--filter "mzShift ' + "${params.msconvert.mz_shift_ppm}" + 'ppm msLevels=1-"'} \
    """
}

/**
 * Calculate a unique hash for msconvert configuration.
 *
 * The hash combines the text of the msconvert command without the raw file and
 * the proteowizard container.
 */
def msconvert_cache_dir() {
    def str = params.images.proteowizard + msconvert_command()
    return str.md5()
}

process MSCONVERT_MULTI_BATCH {
    storeDir "${params.mzml_cache_directory}/${msconvert_cache_dir()}"
    publishDir params.output_directories.msconvert, pattern: "*.mzML", failOnError: true, mode: 'copy', enabled: params.msconvert_only && !params.panorama.upload
    label 'process_medium'
    label 'process_high_memory'
    label 'error_retry'
    label 'proteowizard'
    container params.images.proteowizard

    input:
        tuple val(batch), path(raw_file)

    output:
        tuple val(batch), path("${raw_file.baseName}.mzML"), emit: mzml_file

    script:

    """
    ${msconvert_command()} ${raw_file}
    """

    stub:
    """
    touch '${raw_file.baseName}.mzML'
    """
}

process MSCONVERT {
    storeDir "${params.mzml_cache_directory}/${msconvert_cache_dir()}"
    publishDir params.output_directories.msconvert, pattern: "*.mzML", failOnError: true, mode: 'copy', enabled: params.msconvert_only && !params.panorama.upload
    label 'process_medium'
    label 'process_high_memory'
    label 'error_retry'
    label 'proteowizard'
    container params.images.proteowizard

    input:
        path(raw_file)

    output:
        path("${raw_file.baseName}.mzML"), emit: mzml_file

    script:

    """
    ${msconvert_command()} ${raw_file}
    """

    stub:
    """
    touch '${raw_file.baseName}.mzML'
    """
}

process UNZIP_DIRECTORY {
    label 'process_medium'
    label 'proteowizard'
    container params.images.proteowizard

    input:
        tuple val(batch), path(zip_file)

    output:
        tuple val(batch), path("${zip_file.baseName}", type: "dir")

    script:
        """
        unzip ${zip_file}
        """

    stub:
        """
        mkdir '${zip_file.baseName}'
        """
}