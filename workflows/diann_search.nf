
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

    main:
        DIANN_SEARCH (
            ms_file_ch.collect(),
            fasta,
            spectral_library
        )

        BLIB_BUILD_LIBRARY(DIANN_SEARCH.out.speclib,
                           DIANN_SEARCH.out.precursor_tsv)

        blib = BLIB_BUILD_LIBRARY.out.blib
}