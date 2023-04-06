// modules
include { PANORAMA_GET_FASTA } from "../modules/panorama"
include { PANORAMA_GET_SPECTRAL_LIBRARY } from "../modules/panorama"

workflow get_input_files {

   emit:
       spectra_files_ch
       fasta
       spectral_library
       from_raw_files
       skyline_template_zipfile

    main:

        // get files from Panorama as necessary
        if(params.fasta.startsWith("https://")) {
            PANORAMA_GET_FASTA(params.fasta)
            fasta = PANORAMA_GET_FASTA.out.panorama_file
        } else {
            fasta = file(params.fasta, checkIfExists: true)
        }

        if(params.spectral_library.startsWith("https://")) {
            PANORAMA_GET_SPECTRAL_LIBRARY(params.spectral_library)
            spectral_library = PANORAMA_GET_SPECTRAL_LIBRARY.out.panorama_file
        } else {
            spectral_library = file(params.spectral_library, checkIfExists: true)
        }

        if(params.skyline_template_file != null) {
            if(params.skyline_template_file.startsWith("https://")) {
                PANORAMA_GET_SKYLINE_TEMPLATE(params.skyline_template_file)
                skyline_template_zipfile = PANORAMA_GET_SKYLINE_TEMPLATE.out.panorama_file
            } else {
                skyline_template_zipfile = file(params.skyline_template_file, checkIfExists: true)
            }
        } else {
            skyline_template_zipfile = file(params.default_skyline_template_file)
        }

        if(params.narrow_window_spectra_dir.contains("https://")) {

            spectra_dirs_ch = Channel.from(params.narrow_window_spectra_dir)
                                    .splitText()               // split multiline input
                                    .map{ it.trim() }          // removing surrounding whitespace
                                    .filter{ it.length() > 0 } // skip empty lines

            // get raw files from panorama
            PANORAMA_GET_RAW_FILE_LIST(spectra_dirs_ch)
            placeholder_ch = PANORAMA_GET_RAW_FILE_LIST.out.raw_file_placeholders.transpose()
            PANORAMA_GET_RAW_FILE(placeholder_ch)
            
            spectra_files_ch = PANORAMA_GET_RAW_FILE.out.panorama_file
            from_raw_files = true;

        } else {

            spectra_dir = file(params.narrow_window_spectra_dir, checkIfExists: true)

            // get our mzML files
            mzml_files = file("$spectra_dir/*.mzML")

            // get our raw files
            raw_files = file("$spectra_dir/*.raw")

            if(mzml_files.size() < 1 && raw_files.size() < 1) {
                error "No raw or mzML files found in: $spectra_dir"
            }

            if(mzml_files.size() > 0) {
                    spectra_files_ch = Channel.fromList(mzml_files)
                    from_raw_files = false;
            } else {
                    spectra_files_ch = Channel.fromList(raw_files)
                    from_raw_files = true;
            }
        }

}
