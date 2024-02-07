
// modules
include { DIANN_SEARCH } from "../modules/diann"
include { DIANN_SEARCH_LIB_FREE } from "../modules/diann"
include { BLIB_BUILD_LIBRARY } from "../modules/diann"

workflow diann_search {
    
    take:
        ms_file_ch
        fasta
        spectral_library

    emit:
        blib
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

        BLIB_BUILD_LIBRARY(diann_results.speclib,
                           diann_results.precursor_tsv)

        blib = BLIB_BUILD_LIBRARY.out.blib
        quant_files = diann_results.quant_files
        speclib = diann_results.speclib
        precursor_tsv = diann_results.precursor_tsv
        stdout = diann_results.stdout
        stderr = diann_results.stderr
}
