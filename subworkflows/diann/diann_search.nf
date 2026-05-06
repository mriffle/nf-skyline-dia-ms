
include { DIANN_SINGLE_SEARCH } from "../../modules/diann"
include { DIANN_BUILD_LIB } from "../../modules/diann"
include { DIANN_QUANT } from "../../modules/diann"
include { DIANN_MBR } from "../../modules/diann"

workflow diann_search_parallel {
    take:
        fasta
        spectral_library
        ms_file_ch
        speclib_only

    main:
        DIANN_QUANT(
            ms_file_ch,
            fasta,
            spectral_library,
            params.diann.search_params
        )

        def mbr_params = params.diann.search_params + (speclib_only == true ? " --id-profiling" : " --rt-profiling")
        DIANN_MBR(
            ms_file_ch.collect(),
            DIANN_QUANT.out.quant_file.collect(),
            fasta,
            spectral_library,
            (speclib_only == true ? "subset_library" : "quant"),
            mbr_params
        )

    emit:
        quant_files       = DIANN_QUANT.out.quant_file
        speclib           = DIANN_MBR.out.speclib
        precursor_report  = DIANN_MBR.out.precursor_report
        stdout            = DIANN_MBR.out.stdout
        stderr            = DIANN_MBR.out.stderr
        diann_version     = DIANN_MBR.out.version
        output_file_stats = DIANN_MBR.out.output_file_stats
}

workflow diann_search_single {
    take:
        fasta
        spectral_library
        ms_file_ch
        speclib_only

    main:
        DIANN_SINGLE_SEARCH(
            ms_file_ch,
            fasta,
            spectral_library,
            (speclib_only == true ? "subset_library" : "quant"),
            params.diann.search_params
        )

    emit:
        quant_files       = DIANN_SINGLE_SEARCH.out.quant_files
        library_parquet   = DIANN_SINGLE_SEARCH.out.library_parquet
        precursor_report  = DIANN_SINGLE_SEARCH.out.precursor_report
        stdout            = DIANN_SINGLE_SEARCH.out.stdout
        stderr            = DIANN_SINGLE_SEARCH.out.stderr
        diann_version     = DIANN_SINGLE_SEARCH.out.version
        output_file_stats = DIANN_SINGLE_SEARCH.out.output_file_stats
}

// Dispatcher: branches on file count and routes to the appropriate underlying workflow.
// MBR is meaningless for a single file (DIA-NN auto-disables it and changes its output
// shape), so the single-file path uses a simpler search that produces a parquet/tsv
// library instead of a .skyline.speclib. The two paths emit speclib (multi) and
// library_parquet (single) on separate channels — only one is non-empty per run.
workflow diann_search {
    take:
        fasta
        spectral_library
        ms_file_ch
        speclib_only

    main:
        ms_files_branched = ms_file_ch.collect().branch {
            single: it.size() == 1
            multi:  it.size() > 1
        }

        diann_search_parallel(
            fasta,
            spectral_library,
            ms_files_branched.multi.flatMap { it },
            speclib_only
        )

        diann_search_single(
            fasta,
            spectral_library,
            ms_files_branched.single.flatMap { it },
            speclib_only
        )

    emit:
        quant_files       = diann_search_parallel.out.quant_files
                                .mix(diann_search_single.out.quant_files.flatten())
        speclib           = diann_search_parallel.out.speclib
        library_parquet   = diann_search_single.out.library_parquet
        precursor_report  = diann_search_parallel.out.precursor_report
                                .mix(diann_search_single.out.precursor_report)
        stdout            = diann_search_parallel.out.stdout
                                .mix(diann_search_single.out.stdout)
        stderr            = diann_search_parallel.out.stderr
                                .mix(diann_search_single.out.stderr)
        diann_version     = diann_search_parallel.out.diann_version
                                .mix(diann_search_single.out.diann_version)
        output_file_stats = diann_search_parallel.out.output_file_stats
                                .mix(diann_search_single.out.output_file_stats)
}
