
// modules
include { ENCYCLOPEDIA_BLIB_TO_DLIB } from "../../modules/encyclopedia"
include { ENCYCLOPEDIA_DLIB_TO_TSV } from "../../modules/encyclopedia"
include { BLIB_BUILD_LIBRARY } from "../../modules/diann"
include { setupPanoramaAPIKeySecret } from '../../modules/panorama.nf'
include { DIANN_SEARCH } from "../../modules/diann"
include { DIANN_BUILD_LIB } from "../../modules/diann"
include { DIANN_QUANT } from "../../modules/diann"
include { DIANN_MBR } from "../../modules/diann"

workflow diann_search_serial {
    take:
        ms_file_ch
        fasta
        spectral_library

    main:

        diann_speclib = null
        if(params.spectral_library) {
            diann_speclib = spectral_library
            predicted_speclib = Channel.empty()
        } else {
            DIANN_BUILD_LIB(
                fasta,
                params.diann.fasta_digest_params
            )
            diann_speclib = DIANN_BUILD_LIB.out.speclib
            predicted_speclib = DIANN_BUILD_LIB.out.speclib
        }

        diann_results = DIANN_SEARCH (
            ms_file_ch.collect(),
            fasta,
            diann_speclib,
            params.diann.search_params
        )

        quant_files       = diann_results.quant_files
        speclib           = diann_results.speclib
        precursor_report  = diann_results.precursor_report
        stdout            = diann_results.stdout
        stderr            = diann_results.stderr
        diann_version     = diann_results.version
        output_file_stats = diann_results.output_file_stats

    emit:
        quant_files
        speclib
        precursor_report
        stdout
        stderr
        predicted_speclib
        diann_version
        output_file_stats
}

workflow diann_search_parallel {
    take:
        ms_file_ch
        fasta
        spectral_library

    main:
        diann_speclib = null
        if(params.spectral_library) {
            diann_speclib = spectral_library
            predicted_speclib = Channel.empty()
        } else {
            DIANN_BUILD_LIB(
                fasta,
                params.diann.fasta_digest_params
            )
            diann_speclib = DIANN_BUILD_LIB.out.speclib
            predicted_speclib = DIANN_BUILD_LIB.out.speclib
        }

        DIANN_QUANT(
            ms_file_ch,
            fasta,
            diann_speclib,
            params.diann.search_params
        )

        DIANN_MBR(
            ms_file_ch.collect(),
            DIANN_QUANT.out.quant_file.collect(),
            fasta,
            diann_speclib,
            params.diann.search_params
        )

    emit:
        quant_files       = DIANN_QUANT.out.quant_file
        speclib           = DIANN_MBR.out.speclib
        precursor_report  = DIANN_MBR.out.precursor_report
        stdout            = DIANN_MBR.out.stdout
        stderr            = DIANN_MBR.out.stderr
        predicted_speclib = diann_speclib
        diann_version     = DIANN_MBR.out.version
        output_file_stats = DIANN_MBR.out.output_file_stats
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

        // diann_search = diann_search_serial(
        diann_search = diann_search_parallel(
            mzml_ch,
            fasta,
            spectral_library_to_use
        )

        // create compatible spectral library for Skyline, if needed
        if(!params.skyline.skip) {
            BLIB_BUILD_LIBRARY(diann_search.speclib,
                               diann_search.precursor_report)

            final_speclib = BLIB_BUILD_LIBRARY.out.blib
        } else {
            final_speclib = Channel.empty()
        }

        // all files to upload to panoramaweb (if requested)
        search_file_ch = diann_search.speclib.concat(
            diann_search.precursor_report
        ).concat(
            diann_search.quant_files.flatten()
        ).concat(
            final_speclib
        ).concat(
            diann_search.stdout
        ).concat(
            diann_search.stderr
        ).concat(
            diann_search.predicted_speclib
        )

    emit:
        final_speclib
        diann_version = diann_search.diann_version
        search_file_stats = diann_search.output_file_stats
        search_files = search_file_ch
}