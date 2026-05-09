
include { diann_search_parallel as diann_full_search } from "./diann_search"
include { diann_search_parallel as diann_subset_search } from "./diann_search"

// modules
include { DIANN_BUILD_LIB } from "../../modules/diann"
include { ENCYCLOPEDIA_BLIB_TO_DLIB } from "../../modules/encyclopedia"
include { ENCYCLOPEDIA_DLIB_TO_TSV } from "../../modules/encyclopedia"
include { BLIB_BUILD_LIBRARY } from "../../modules/diann"

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

        // DIA-NN's match-between-runs step needs at least 2 runs to emit the spectral
        // library that BlibBuild consumes (and that DIANN_MBR declares as a required
        // output). The same constraint applies to the narrow-window subset search when
        // a chromatogram-library spectra dir is configured. File counts are only
        // knowable once the resolver channels materialize (PDC/Panorama listings,
        // optional sampling), so build a combined deferred validator that names exactly
        // which input(s) are too small, and gate both search-input channels on it via
        // .first() so the same value channel can be reused.
        def wide_count_ch = wide_ms_file_ch.toList().map { it.size() }
        def narrow_count_ch
        if (params.chromatogram_library_spectra_dir != null) {
            narrow_count_ch = narrow_ms_file_ch.toList().map { it.size() }
        } else {
            // Sentinel: -1 means "narrow input was not configured; skip the narrow check".
            narrow_count_ch = Channel.value(-1)
        }

        def validation_ch = wide_count_ch.combine(narrow_count_ch).map { counts ->
            def wide = counts[0]
            def narrow = counts[1]
            def problems = []
            if (wide < 2) {
                problems << "wide-window quant input ('quant_spectra_dir') has ${wide} file${wide == 1 ? '' : 's'}"
            }
            if (narrow >= 0 && narrow < 2) {
                problems << "narrow-window/GPF input ('chromatogram_library_spectra_dir') has ${narrow} file${narrow == 1 ? '' : 's'}"
            }
            if (problems) {
                error "DIA-NN requires at least 2 MS files for each input it searches. Found:\n" +
                      "  - ${problems.join('\n  - ')}\n" +
                      "DIA-NN's match-between-runs step needs two or more runs to emit the " +
                      "spectral library used downstream. Provide additional MS files, or use " +
                      "a different search engine."
            }
            true
        }.first()

        wide_ms_file_ch = wide_ms_file_ch.combine(validation_ch).map { it[0] }
        if (params.chromatogram_library_spectra_dir != null) {
            narrow_ms_file_ch = narrow_ms_file_ch.combine(validation_ch).map { it[0] }
        }

        if (params.encyclopedia.quant.params != null) {
            log.warn "The parameter 'encyclopedia.quant.params' is set to a value (${params.encyclopedia.quant.params}) but will be ignored."
        }

        if (params.encyclopedia.chromatogram.params != null) {
            log.warn "The parameter 'encyclopedia.chromatogram.params' is set to a value (${params.encyclopedia.chromatogram.params}) but will be ignored."
        }

        if (params.carafe.spectra_file || params.carafe.spectra_dir ||
                params.carafe.pdc_files || params.carafe.pdc_n_files) {
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
            spectral_library_to_use = diann_subset_search.out.speclib
        }

        diann_full_search(
            fasta,
            spectral_library_to_use,
            wide_ms_file_ch,
            false
        )

        // create compatible spectral library for Skyline, if needed
        if(!params.skyline.skip) {
            BLIB_BUILD_LIBRARY(diann_full_search.out.speclib,
                               diann_full_search.out.precursor_report)

            final_speclib = BLIB_BUILD_LIBRARY.out.blib
        } else {
            final_speclib = Channel.empty()
        }

        // all files to upload to panoramaweb (if requested)
        search_file_ch = diann_full_search.out.speclib.concat(
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
