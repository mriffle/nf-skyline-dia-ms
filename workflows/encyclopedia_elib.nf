// Modules
include { ENCYCLOPEDIA_SEARCH_FILE } from "../modules/encyclopedia"
include { ENCYCLOPEDIA_CREATE_ELIB } from "../modules/encyclopedia"

workflow encyclopeda_export_elib {

    take:
        mzml_file_ch
        fasta
        dlib
    
    main:

        // run encyclopedia for each mzML file
        ENCYCLOPEDIA_SEARCH_FILE(mzml_file_ch, fasta, dlib)

        // aggregate results into single elib
        ENCYCLOPEDIA_CREATE_ELIB(
            mzml_file_ch.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.elib.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.dia.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.features.collect(),
            ENCYCLOPEDIA_SEARCH_FILE.out.results_targets.collect(),
            fasta,
            dlib
        )

}
