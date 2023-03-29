// Modules
include { MSCONVERT } from "../modules/msconvert"
include { ENCYCLOPEDIA_SEARCH_FILE } from "../modules/encyclopedia"
include { ENCYCLOPEDIA_CREATE_ELIB } from "../modules/encyclopedia"

workflow encyclopeda_export_elib {

    take:
        spectra_file_ch
        fasta
        dlib
        from_raw_files
        do_demultiplex
        do_simasspectra
    
    main:

        // convert raw files to mzML files if necessary
        if(from_raw_files) {
            mzml_file_ch = MSCONVERT(spectra_file_ch, do_demultiplex, do_simasspectra)
        } else {
            mzml_file_ch = spectra_file_ch
        }

        // run encyclopedia for each mzML file
        ENCYCLOPEDIA_SEARCH_FILE(mzml_file_ch, fasta, dlib)


}
