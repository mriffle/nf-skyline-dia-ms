
// modules
include { DIANN_SEARCH } from "../modules/diann"
include { DIANN_SEARCH_LIB_FREE } from "../modules/diann"

workflow diann_search {
    
    take:
        ms_file_ch
        fasta
        spectral_library

    emit:
        quant_files
        speclib
        precursor_tsv
        stdout
        stderr

    main:

        diann_results = null
        if(params.spectral_library) {
            diann_results = DIANN_SEARCH (
                ms_file_ch.collect(),
                fasta,
                spectral_library,
                params.diann.params
            )
        } else {
            diann_results = DIANN_SEARCH_LIB_FREE (
                ms_file_ch.collect(),
                fasta,
                params.diann.params
            )
        }

        quant_files   = diann_results.quant_files
        speclib       = diann_results.speclib
        precursor_tsv = diann_results.precursor_tsv
        stdout        = diann_results.stdout
        stderr        = diann_results.stderr
}
