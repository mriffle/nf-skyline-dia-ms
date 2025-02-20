// modules
include { CASCADIA_SEARCH } from "../modules/cascadia"
include { CASCADIA_FIX_SCAN_NUMBERS } from "../modules/cascadia"
include { CASCADIA_CREATE_FASTA } from "../modules/cascadia"
include { CASCADIA_COMBINE_SSL_FILES } from "../modules/cascadia"
include { BLIB_BUILD_LIBRARY } from "../modules/cascadia"

workflow cascadia_search {

    take:
        ms_file_ch

    emit:
        blib
        fasta
        stdout
        stderr
        cascadia_version
        output_file_stats

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
}
