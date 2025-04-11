
// subworkflows
include { run_carafe } from "../subworkflows/run_carafe"
include { get_input_file as get_input_fasta } from "../subworkflows/get_input_file"
include { get_input_file as get_peptide_results } from "../subworkflows/get_input_file"
include { diann_search_parallel as diann_search} from "../subworkflows/diann/diann_search"

include { PANORAMA_GET_MS_FILE } from "../modules/panorama"
include { PANORAMA_PUBLIC_GET_MS_FILE } from "../modules/panorama"
include { MSCONVERT } from "../modules/msconvert"
include { DIANN_BUILD_LIB } from "../modules/diann"

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
            get_input_fasta(params.carafe.fasta, aws_secret_id)
            carafe_fasta = get_input_fasta.out.file
        }
        if (params.carafe.diann_fasta == null){
            diann_fasta = carafe_fasta
        } else {
            get_input_fasta(params.carafe.fasta, aws_secret_id)
            diann_fasta = get_input_fasta.out.file
        }

        // Get input spectral file
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

        // Convert spectral file to mzML if necissary
        input_spectral_raw_file.branch{
            mzml: it.name.endsWith('.mzML')
            raw: it.name.endsWith('.raw')
            other: true
                error "Unknown file type:" + it.name
        }.set{ branched_ms_file_ch }

        MSCONVERT(branched_ms_file_ch.raw)

        spectra_file = MSCONVERT.out.concat(branched_ms_file_ch.mzml)

        // Get carafe input peptide results file
        if (params.carafe.peptide_results_file != null){
            get_peptide_results(params.carafe.peptide_results_file, aws_secret_id)
            carafe_psm_file = get_peptide_results.out.file
        } else {
            DIANN_BUILD_LIB(diann_fasta, params.diann.fasta_digest_params)
            diann_search(diann_fasta,
                         DIANN_BUILD_LIB.out.speclib,
                         spectra_file,
                         false)
            carafe_psm_file = diann_search.out.precursor_report
        }

        run_carafe(spectra_file,
                   carafe_fasta,
                   carafe_psm_file,
                   params.carafe.cli_options,
                   params.search_engine)

    emit:
        spectral_library = run_carafe.out.speclib_tsv
        carafe_version = run_carafe.out.carafe_version
}
