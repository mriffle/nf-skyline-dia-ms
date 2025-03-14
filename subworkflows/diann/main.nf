
// modules
include { ENCYCLOPEDIA_BLIB_TO_DLIB } from "../../modules/encyclopedia"
include { ENCYCLOPEDIA_DLIB_TO_TSV } from "../../modules/encyclopedia"
include { BLIB_BUILD_LIBRARY } from "../../modules/diann"
include { setupPanoramaAPIKeySecret } from '../../modules/panorama.nf'
include { DIANN_SEARCH } from "../../modules/diann"
include { DIANN_SEARCH_LIB_FREE } from "../../modules/diann"

workflow diann_search {
    take:
        ms_file_ch
        fasta
        spectral_library

    main:

        diann_results = null
        if(params.spectral_library) {
            diann_results = DIANN_SEARCH (
                ms_file_ch.collect(),
                fasta,
                spectral_library,
                params.diann.params
            )
            diann_version = DIANN_SEARCH.out.version
            output_file_stats = DIANN_SEARCH.out.output_file_stats

            predicted_speclib = Channel.empty()
        } else {
            diann_results = DIANN_SEARCH_LIB_FREE (
                ms_file_ch.collect(),
                fasta,
                params.diann.params
            )

            diann_version = DIANN_SEARCH_LIB_FREE.out.version
            predicted_speclib = diann_results.predicted_speclib
            output_file_stats = DIANN_SEARCH_LIB_FREE.out.output_file_stats
        }

        quant_files       = diann_results.quant_files
        speclib           = diann_results.speclib
        precursor_tsv     = diann_results.precursor_tsv
        stdout            = diann_results.stdout
        stderr            = diann_results.stderr

    emit:
        quant_files
        speclib
        precursor_tsv
        stdout
        stderr
        predicted_speclib
        diann_version
        output_file_stats
}

workflow diann {
    take:
        fasta
        spectral_library
        mzml_ch

    main:
        if(!params.fasta) {
            error "The parameter \'fasta\' is required when using diann."
        }

        if (params.chromatogram_library_spectra_dir != null) {
            log.warn "The parameter 'chromatogram_library_spectra_dir' is set to a value (${params.chromatogram_library_spectra_dir}) but will be ignored."
        }

        if (params.encyclopedia.quant.params != null) {
            log.warn "The parameter 'encyclopedia.quant.params' is set to a value (${params.encyclopedia.quant.params}) but will be ignored."
        }

        if (params.encyclopedia.chromatogram.params != null) {
            log.warn "The parameter 'encyclopedia.chromatogram.params' is set to a value (${params.encyclopedia.chromatogram.params}) but will be ignored."
        }

        if(params.spectral_library) {

            // convert spectral library to required format for dia-nn
            if(params.spectral_library.endsWith(".blib")) {
                ENCYCLOPEDIA_BLIB_TO_DLIB(
                    fasta,
                    spectral_library
                )

                ENCYCLOPEDIA_DLIB_TO_TSV(
                    ENCYCLOPEDIA_BLIB_TO_DLIB.out.dlib
                )

                spectral_library_to_use = ENCYCLOPEDIA_DLIB_TO_TSV.out.tsv

            } else if(params.spectral_library.endsWith(".dlib")) {
                ENCYCLOPEDIA_DLIB_TO_TSV(
                    spectral_library
                )

                spectral_library_to_use = ENCYCLOPEDIA_DLIB_TO_TSV.out.tsv

            } else {
                spectral_library_to_use = spectral_library
            }
        } else {
            // no spectral library
            spectral_library_to_use = Channel.empty()
        }

        diann_search(
            mzml_ch,
            fasta,
            spectral_library_to_use
        )

        // create compatible spectral library for Skyline, if needed
        if(!params.skyline.skip) {
            BLIB_BUILD_LIBRARY(diann_search.out.speclib,
                            diann_search.out.precursor_tsv)

            final_speclib = BLIB_BUILD_LIBRARY.out.blib
        } else {
            final_speclib = Channel.empty()
        }

        // all files to upload to panoramaweb (if requested)
        search_file_ch = diann_search.out.speclib.concat(
            diann_search.out.precursor_tsv
        ).concat(
            diann_search.out.quant_files.flatten()
        ).concat(
            final_speclib
        ).concat(
            diann_search.out.stdout
        ).concat(
            diann_search.out.stderr
        ).concat(
            diann_search.out.predicted_speclib
        )

    emit:
        final_speclib
        diann_version = diann_search.out.diann_version
        search_file_stats = diann_search.out.output_file_stats
        search_files = search_file_ch
}