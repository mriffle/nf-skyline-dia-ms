
// modules
include { DIANN_SEARCH } from "../modules/diann"
include { DIANN_SEARCH_LIB_FREE } from "../modules/diann"

workflow diann_search {

    take:
        ms_file_ch
        fasta
        spectral_library

    main:

        diann_results = null
        if(params.spectral_library) {
            diann_results = DIANN_SEARCH (
                ms_file_ch.collect(),
                fasta,
                spectral_library,
                params.diann.params
            )
            diann_version = DIANN_SEARCH.out.version
            output_file_stats = DIANN_SEARCH.out.output_file_stats

            predicted_speclib = Channel.empty()
        } else {
            diann_results = DIANN_SEARCH_LIB_FREE (
                ms_file_ch.collect(),
                fasta,
                params.diann.params
            )

            diann_version = DIANN_SEARCH_LIB_FREE.out.version
            predicted_speclib = diann_results.predicted_speclib
            output_file_stats = DIANN_SEARCH_LIB_FREE.out.output_file_stats
        }

        quant_files       = diann_results.quant_files
        speclib           = diann_results.speclib
        precursor_tsv     = diann_results.precursor_tsv
        stdout            = diann_results.stdout
        stderr            = diann_results.stderr

    emit:
        quant_files
        speclib
        precursor_tsv
        stdout
        stderr
        predicted_speclib
        diann_version
        output_file_stats
}
