// modules
include { PANORAMA_GET_RAW_FILE } from "../modules/panorama"
include { PANORAMA_GET_RAW_FILE_LIST } from "../modules/panorama"
include { MSCONVERT } from "../modules/msconvert"

workflow get_wide_mzmls {

   emit:
       wide_mzml_ch

    main:

        if(params.wide_window_spectra_dir.contains("https://")) {

            spectra_dirs_ch = Channel.from(params.wide_window_spectra_dir)
                                    .splitText()               // split multiline input
                                    .map{ it.trim() }          // removing surrounding whitespace
                                    .filter{ it.length() > 0 } // skip empty lines

            // get raw files from panorama
            PANORAMA_GET_RAW_FILE_LIST(spectra_dirs_ch)
            placeholder_ch = PANORAMA_GET_RAW_FILE_LIST.out.raw_file_placeholders.transpose()
            PANORAMA_GET_RAW_FILE(placeholder_ch)
            
            wide_mzml_ch = MSCONVERT(
                PANORAMA_GET_RAW_FILE.out.panorama_file,
                params.do_demultiplex,
                params.do_simasspectra
            )

        } else {

            spectra_dir = file(params.wide_window_spectra_dir, checkIfExists: true)

            // get our mzML files
            mzml_files = file("$spectra_dir/*.mzML")

            // get our raw files
            raw_files = file("$spectra_dir/*.raw")

            if(mzml_files.size() < 1 && raw_files.size() < 1) {
                error "No raw or mzML files found in: $spectra_dir"
            }

            if(mzml_files.size() > 0) {
                    wide_mzml_ch = Channel.fromList(mzml_files)
            } else {
                wide_mzml_ch = MSCONVERT(
                    Channel.fromList(raw_files),
                    params.do_demultiplex,
                    params.do_simasspectra
                )
            }
        }

}
