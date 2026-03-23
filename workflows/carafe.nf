
// subworkflows
include { run_carafe } from "../subworkflows/run_carafe"
include { get_input_file as get_carafe_fasta } from "../subworkflows/get_input_file"
include { get_input_file as get_diann_fasta } from "../subworkflows/get_input_file"
include { get_input_file as get_peptide_results } from "../subworkflows/get_input_file"

include { PANORAMA_GET_MS_FILE } from "../modules/panorama"
include { PANORAMA_PUBLIC_GET_MS_FILE } from "../modules/panorama"
include { MSCONVERT } from "../modules/msconvert"
include { DIANN_BUILD_LIB } from "../modules/diann"
include { CARAFE_DIANN_SEARCH as DIANN_SEARCH } from "../modules/diann"
include { get_ms_files as get_carafe_ms_files } from "../subworkflows/get_ms_files"

include { panorama_auth_required_for_url } from "../subworkflows/get_ms_files"
include { is_panorama_url } from "../subworkflows/get_ms_files"

workflow carafe {
    take:
        input_fasta
        aws_secret_id

    main:
        // Get input fasta files
        if (params.carafe.carafe_fasta == null){
            carafe_fasta = input_fasta
        } else {
            get_carafe_fasta(params.carafe.carafe_fasta, aws_secret_id)
            carafe_fasta = get_carafe_fasta.out.file
        }
        if (params.carafe.diann_fasta == null){
            diann_fasta = carafe_fasta
        } else {
            get_diann_fasta(params.carafe.diann_fasta, aws_secret_id)
            diann_fasta = get_diann_fasta.out.file
        }

        if (params.carafe.spectra_file != null && params.carafe.spectra_dir != null) {
            error "Only one of params.carafe.spectra_file or params.carafe.spectra_dir may be set."
        }

        // Resolve Carafe input spectra, keeping legacy single-file behavior intact.
        if (params.carafe.spectra_file != null) {
            if (is_panorama_url(params.carafe.spectra_file)) {
                batched_url_ch = Channel.value(params.carafe.spectra_file)
                    .map{ it -> ['dummy_batch', it] }

                if(panorama_auth_required_for_url(params.carafe.spectra_file)) {
                    panorama_download = PANORAMA_GET_MS_FILE(batched_url_ch, aws_secret_id)
                } else {
                    panorama_download = PANORAMA_PUBLIC_GET_MS_FILE(batched_url_ch)
                }
                input_spectral_raw_file = panorama_download.panorama_file.map{ it -> it[1] }
            } else {
                input_spectral_raw_file = Channel.value(file(params.carafe.spectra_file, checkIfExists: true))
            }
        } else {
            String carafe_spectra_regex = get_carafe_file_regex(
                params.carafe.spectra_glob,
                params.carafe.spectra_regex
            )
            get_carafe_ms_files(params.carafe.spectra_dir, carafe_spectra_regex, null, aws_secret_id)
            input_spectral_raw_file = get_carafe_ms_files.out.ms_file_ch.map{ it[1] }
        }

        // Convert spectral files to mzML if necessary.
        input_spectral_raw_file.branch{
            mzml: it.name.endsWith('.mzML')
            raw: it.name.endsWith('.raw')
            other: true
                error "Carafe spectra inputs must be .raw or .mzML files. Found: ${it.name}"
        }.set{ branched_ms_file_ch }

        MSCONVERT(branched_ms_file_ch.raw)

        spectra_files = MSCONVERT.out
            .concat(branched_ms_file_ch.mzml)
            .collect()
            .map{ file_list ->
                def sorted_file_list = file_list.sort { a, b -> a.toString() <=> b.toString() }
                if (params.carafe.spectra_file != null && sorted_file_list.size() != 1) {
                    error "There must be exactly 1 Carafe spectra_file! Found ${sorted_file_list.size()}:\n\t${sorted_file_list.join(', ')}"
                }
                if (sorted_file_list.isEmpty()) {
                    error "No Carafe spectra files were resolved."
                }
                return sorted_file_list
            }

        // Get carafe input peptide results file
        if (params.carafe.peptide_results_file != null){
            get_peptide_results(params.carafe.peptide_results_file, aws_secret_id)
            carafe_psm_file = get_peptide_results.out.file
        } else {
            DIANN_BUILD_LIB(diann_fasta, params.diann.fasta_digest_params)
            def diann_search_params = "--qvalue 0.01"
            DIANN_SEARCH(spectra_files,
                         diann_fasta,
                         DIANN_BUILD_LIB.out.speclib,
                         'carafe_input',
                         diann_search_params)

            carafe_psm_file = DIANN_SEARCH.out.precursor_report
        }

        search_engine = params.search_engine == null ? 'diann' : params.search_engine.toLowerCase()
        run_carafe(spectra_files,
                   carafe_fasta,
                   carafe_psm_file,
                   params.carafe.cli_options,
                   params.carafe.include_phosphorylation,
                   params.carafe.include_oxidized_methionine,
                   params.carafe.max_mod_option,
                   search_engine)

        // We need to make sure speclib_tsv is a value channel
        // because Nextflow thinks it should be a queue channel
        spectral_library = run_carafe.out.speclib_tsv.first()

    emit:
        spectral_library
        carafe_version = run_carafe.out.carafe_version
}

def escape_regex(String str) {
    return str.replaceAll(/([.\^$+?{}\[\]\\|()])/) { _, group -> '\\' + group }
}

def get_carafe_file_regex(String file_glob_param, String file_regex_param) {
    if (file_glob_param != null && file_regex_param != null) {
        error "Either params.carafe.spectra_glob or params.carafe.spectra_regex can be set, but not both."
    }
    if (file_regex_param != null) {
        return file_regex_param
    }
    if (file_glob_param != null) {
        return '^' + escape_regex(file_glob_param).replaceAll('\\*', '.*') + '$'
    }
    error "Neither params.carafe.spectra_glob nor params.carafe.spectra_regex is set."
}
