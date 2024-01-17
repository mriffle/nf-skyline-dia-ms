
// modules
include { DIANN_SEARCH } from "../modules/diann"
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

    main:
        DIANN_SEARCH (
            ms_file_ch.collect(),
            fasta,
            spectral_library
        )

        BLIB_BUILD_LIBRARY(DIANN_SEARCH.out.speclib,
                           DIANN_SEARCH.out.precursor_tsv)

        blib = BLIB_BUILD_LIBRARY.out.blib
        quant_files = DIANN_SEARCH.out.quant_files
        speclib = DIANN_SEARCH.out.speclib
        precursor_tsv = DIANN_SEARCH.out.precursor_tsv
}