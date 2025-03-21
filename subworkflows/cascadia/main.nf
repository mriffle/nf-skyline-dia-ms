
// modules
include { CASCADIA_SEARCH } from "../../modules/cascadia"
include { CASCADIA_FIX_SCAN_NUMBERS } from "../../modules/cascadia"
include { CASCADIA_CREATE_FASTA } from "../../modules/cascadia"
include { CASCADIA_COMBINE_SSL_FILES } from "../../modules/cascadia"
include { BLIB_BUILD_LIBRARY } from "../../modules/cascadia"

workflow cascadia_search {

    take:
        ms_file_ch

    main:

        // run cascadia on all mzML files
        CASCADIA_SEARCH (
            ms_file_ch
        )

        // fix the scan numbers in the results for each mzML file
        CASCADIA_FIX_SCAN_NUMBERS (
            CASCADIA_SEARCH.out.ssl
        )

        // combine ssl files into one
        CASCADIA_COMBINE_SSL_FILES(
            CASCADIA_FIX_SCAN_NUMBERS.out.fixed_ssl.collect()
        )

        // create blib
        BLIB_BUILD_LIBRARY(
            CASCADIA_COMBINE_SSL_FILES.out.ssl,
            ms_file_ch.collect()
        )

        // create the fasta used downstream to build skyline document
        CASCADIA_CREATE_FASTA(
            CASCADIA_COMBINE_SSL_FILES.out.ssl
        )

        blib = BLIB_BUILD_LIBRARY.out.blib
        fasta = CASCADIA_CREATE_FASTA.out.fasta
        cascadia_version  = CASCADIA_SEARCH.out.version
        output_file_stats = CASCADIA_SEARCH.out.output_file_stats
        stdout            = CASCADIA_SEARCH.out.stdout
        stderr            = CASCADIA_SEARCH.out.stderr

    emit:
        blib
        fasta
        stdout
        stderr
        cascadia_version
        output_file_stats
}

workflow cascadia {
    take:
        mzml_ch

    main:
        if (params.spectral_library != null) {
            log.warn "The parameter 'spectral_library' is set to a value (${params.spectral_library}) but will be ignored."
        }

        cascadia_search(
            mzml_ch
        )

        // all files to upload to panoramaweb (if requested)
        all_search_file_ch = cascadia_search.out.blib.concat(
            cascadia_search.out.fasta
        ).concat(
            cascadia_search.out.stdout
        ).concat(
            cascadia_search.out.stderr
        )

    emit:
        cascadia_version = cascadia_search.out.cascadia_version
        all_search_files = all_search_file_ch
        final_speclib = cascadia_search.out.blib
        fasta = cascadia_search.out.fasta
        search_file_stats = cascadia_search.out.output_file_stats
}