
include { diann_search as diann_full_search } from "./diann_search"
include { diann_search as diann_subset_search } from "./diann_search"

// modules
include { DIANN_BUILD_LIB } from "../../modules/diann"
include { ENCYCLOPEDIA_BLIB_TO_DLIB } from "../../modules/encyclopedia"
include { ENCYCLOPEDIA_DLIB_TO_TSV } from "../../modules/encyclopedia"
include { BLIB_BUILD_LIBRARY } from "../../modules/diann"
include { DIANN_LIB_PARQUET_TO_TSV } from "../../modules/diann"
include { BLIB_BUILD_LIBRARY_FROM_TSV } from "../../modules/diann"

workflow diann {
    take:
        fasta
        spectral_library
        wide_ms_file_ch
        narrow_ms_file_ch
        use_batch_mode

    main:
        if (!params.fasta) {
            error "The parameter \'fasta\' is required when using diann."
        }

        if (params.encyclopedia.quant.params != null) {
            log.warn "The parameter 'encyclopedia.quant.params' is set to a value (${params.encyclopedia.quant.params}) but will be ignored."
        }

        if (params.encyclopedia.chromatogram.params != null) {
            log.warn "The parameter 'encyclopedia.chromatogram.params' is set to a value (${params.encyclopedia.chromatogram.params}) but will be ignored."
        }

        if (params.carafe.spectra_file || params.carafe.spectra_dir) {
            spectral_library_to_use = spectral_library
            predicted_speclib = Channel.empty()
        }
        else if (params.spectral_library) {

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
            predicted_speclib = Channel.empty()
        } else {
            // create predicted spectral library from fasta
            DIANN_BUILD_LIB(
                fasta,
                params.diann.fasta_digest_params
            )
            spectral_library_to_use = DIANN_BUILD_LIB.out.speclib
            predicted_speclib = DIANN_BUILD_LIB.out.speclib
        }

        if (params.chromatogram_library_spectra_dir) {
            diann_subset_search(
                fasta,
                spectral_library_to_use,
                narrow_ms_file_ch,
                true
            )
            // Multi-file subset search emits speclib; single-file emits library_parquet.
            // Either is accepted by DIA-NN as --lib for the subsequent full search.
            spectral_library_to_use = diann_subset_search.out.speclib
                                          .mix(diann_subset_search.out.library_parquet)
        }

        diann_full_search(
            fasta,
            spectral_library_to_use,
            wide_ms_file_ch,
            false
        )

        // create compatible spectral library for Skyline, if needed
        if(!params.skyline.skip) {
            // Multi-file path: existing .skyline.speclib → .blib
            BLIB_BUILD_LIBRARY(diann_full_search.out.speclib,
                               diann_full_search.out.precursor_report)

            // Single-file path: parquet library → TSV → .blib (BlibBuild can't read parquet,
            // and DIA-NN only emits .skyline.speclib when MBR engages, which requires 2+ files)
            DIANN_LIB_PARQUET_TO_TSV(diann_full_search.out.library_parquet)
            BLIB_BUILD_LIBRARY_FROM_TSV(DIANN_LIB_PARQUET_TO_TSV.out.library_tsv)

            final_speclib = BLIB_BUILD_LIBRARY.out.blib
                                .mix(BLIB_BUILD_LIBRARY_FROM_TSV.out.blib)
                                .first()
            single_file_library_tsv = DIANN_LIB_PARQUET_TO_TSV.out.library_tsv
        } else {
            final_speclib = Channel.empty()
            single_file_library_tsv = Channel.empty()
        }

        // all files to upload to panoramaweb (if requested)
        search_file_ch = diann_full_search.out.speclib.concat(
            diann_full_search.out.library_parquet
        ).concat(
            single_file_library_tsv
        ).concat(
            diann_full_search.out.precursor_report
        ).concat(
            diann_full_search.out.quant_files.flatten()
        ).concat(
            final_speclib
        ).concat(
            diann_full_search.out.stdout
        ).concat(
            diann_full_search.out.stderr
        ).concat(
            predicted_speclib
        )

    emit:
        final_speclib
        diann_version = diann_full_search.out.diann_version
        search_file_stats = diann_full_search.out.output_file_stats
        search_files = search_file_ch
}
