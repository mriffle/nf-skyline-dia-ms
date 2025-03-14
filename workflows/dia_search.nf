
include { encyclopedia } from "../subworkflows/encyclopedia"
include { diann } from "../subworkflows/diann"
include { cascadia } from "../subworkflows/cascadia"

workflow dia_search{
    take:
        search_engine
        fasta
        spectral_library
        narrow_mzml_ch
        wide_mzml_ch

    main:

        // Variables which must be defined by earch search engine
        search_engine_version = null
        all_search_file_ch = null
        final_speclib = null
        search_file_stats = null
        search_fasta = null

        if(search_engine.toLowerCase() == 'encyclopedia') {

            encyclopedia(fasta, spectral_library,
                         narrow_mzml_ch, wide_mzml_ch)

            search_engine_version = encyclopedia.out.encyclopedia_version
            search_file_stats = encyclopedia.out.search_file_stats
            final_speclib = encyclopedia.out.final_elib
            all_search_file_ch = encyclopedia.out.search_files
            search_fasta = fasta

        } else if(search_engine.toLowerCase() == 'diann') {

            diann(fasta, spectral_library, wide_mzml_ch)

            search_engine_version = diann.out.diann_version
            search_file_stats = diann.out.search_file_stats
            final_speclib = diann.out.final_speclib
            all_search_file_ch = diann.out.search_files
            search_fasta = fasta

        } else if(search_engine.toLowerCase() == 'cascadia') {
            cascadia(wide_mzml_ch)

            search_engine_version = cascadia.out.cascadia_version
            search_file_stats = cascadia.out.search_file_stats
            final_speclib = cascadia.out.final_speclib
            all_search_file_ch = cascadia.out.all_search_files
            search_fasta = cascadia.out.fasta

        } else {
            error "'${search_engine}' is an invalid argument for params.search_engine!"
        }

        // Check that all required variables were defined
        if(search_engine_version == null) {
            error "Search engine version not set!"
        }
        if(all_search_file_ch == null) {
            error "Search engine file Channel not set!"
        }
        if(final_speclib == null) {
            error "Final spectral library not set!"
        }
        if(search_file_stats == null) {
            error "Search file stats not set!"
        }
        if(search_fasta == null) {
            error "Search file fasta not set!"
        }

    emit:
        search_engine_version
        all_search_files = all_search_file_ch
        search_file_stats
        final_speclib
        search_fasta
}