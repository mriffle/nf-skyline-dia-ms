// Modules
include { ENCYCLOPEDIA_SEARCH_FILE } from "../modules/encyclopedia"
include { ENCYCLOPEDIA_CREATE_ELIB } from "../modules/encyclopedia"

workflow encyclopedia_search {

    take:
        mzml_file_ch
        fasta
        lib
        align
        output_file_prefix
        encyclopedia_params

    emit:
        individual_elibs
        elib
        peptide_quant
        protein_quant

    main:

        // run encyclopedia for each mzML file
        ENCYCLOPEDIA_SEARCH_FILE(
            mzml_file_ch,
            fasta,
            lib,
            encyclopedia_params
        )

        individual_elibs = ENCYCLOPEDIA_SEARCH_FILE.out.elib

        // aggregate results into single elib
        ENCYCLOPEDIA_CREATE_ELIB(
            ENCYCLOPEDIA_SEARCH_FILE.out.elib.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.dia.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.features.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.results_targets.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.results_decoys.collect(),
            fasta,
            lib,
            align,
            output_file_prefix,
            encyclopedia_params
        )

        elib = ENCYCLOPEDIA_CREATE_ELIB.out.elib
        peptide_quant = ENCYCLOPEDIA_CREATE_ELIB.out.peptide_quant
        protein_quant = ENCYCLOPEDIA_CREATE_ELIB.out.protein_quant
}
