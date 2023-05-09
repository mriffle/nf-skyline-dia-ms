// modules
include { PANORAMA_GET_RAW_FILE } from "../modules/panorama"
include { PANORAMA_GET_RAW_FILE_LIST } from "../modules/panorama"
include { MSCONVERT } from "../modules/msconvert"

def convertFileGlobsToRegexPattern(String pattern) {
    def regex = pattern.replaceAll('\\.', '\\\\.')
    regex = regex.replaceAll('\\*', '.*')
    "^${regex}\$"
}

workflow get_wide_mzmls {

   emit:
       wide_mzml_ch

    main:

        if(params.quant_spectra_dir.contains("https://")) {

            spectra_dirs_ch = Channel.from(params.quant_spectra_dir)
                                    .splitText()               // split multiline input
                                    .map{ it.trim() }          // removing surrounding whitespace
                                    .filter{ it.length() > 0 } // skip empty lines

            // get raw files from panorama
            PANORAMA_GET_RAW_FILE_LIST(spectra_dirs_ch)
            placeholder_ch = PANORAMA_GET_RAW_FILE_LIST.out.raw_file_placeholders.transpose()
            PANORAMA_GET_RAW_FILE(placeholder_ch)
            
            wide_mzml_ch = MSCONVERT(
                PANORAMA_GET_RAW_FILE.out.panorama_file,
                params.msconvert.do_demultiplex,
                params.msconvert.do_simasspectra
            )

        } else {

            file_glob = params.quant_spectra_glob
            spectra_dir = file(params.quant_spectra_dir, checkIfExists: true)
            data_files = file("$spectra_dir/${file_glob}")

            if(data_files.size() < 1) {
                error "No files found for: $spectra_dir/${file_glob}"
            }

            println data_files

            mzml_files = data_files.findAll { it -> it.endsWith('.mzML') }
            raw_files = data_files.findAll { it -> it.endsWith('.raw') }

            println raw_files

            if(mzml_files.size() < 1 && raw_files.size() < 1) {
                error "No raw or mzML files found in: $spectra_dir"
            }

            if(mzml_files.size() > 0 && raw_files.size() > 0) {
                error "Matched raw files and mzML files in: $spectra_dir. Please choose a file matching string that will only match one or the other."
            }

            if(mzml_files.size() > 0) {
                    wide_mzml_ch = Channel.fromList(mzml_files)
            } else {
                wide_mzml_ch = MSCONVERT(
                    Channel.fromList(raw_files),
                    params.msconvert.do_demultiplex,
                    params.msconvert.do_simasspectra
                )
            }
        }
}
