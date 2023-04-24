// Modules
include { ENCYCLOPEDIA_SEARCH_FILE } from "../modules/encyclopedia"
include { ENCYCLOPEDIA_CREATE_ELIB } from "../modules/encyclopedia"

workflow encyclopedia_quant {

    take:
        mzml_file_ch
        fasta
        elib

    emit:
        final_elib
    
    main:

        // run encyclopedia for each mzML file
        ENCYCLOPEDIA_SEARCH_FILE(
            mzml_file_ch, 
            fasta,
            elib,
            params.encyclopedia.quant.params
        )

        // aggregate results into single elib
        ENCYCLOPEDIA_CREATE_ELIB(
            ENCYCLOPEDIA_SEARCH_FILE.out.elib.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.dia.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.features.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.results_targets.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.results_decoys.collect(),
            fasta,
            elib,
            'true',
            'wide',
            params.encyclopedia.quant.params
        )

        final_elib = ENCYCLOPEDIA_CREATE_ELIB.out.elib


}
