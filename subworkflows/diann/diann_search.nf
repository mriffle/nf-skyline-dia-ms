
include { DIANN_SEARCH } from "../../modules/diann"
include { DIANN_BUILD_LIB } from "../../modules/diann"
include { DIANN_QUANT } from "../../modules/diann"
include { DIANN_MBR } from "../../modules/diann"

workflow diann_search_serial {
    take:
        fasta
        spectral_library
        ms_file_ch
        speclib_only

    main:
        def search_params = params.diann.search_params + (speclib_only == true ? " --reanalyze" : "")

        diann_results = DIANN_SEARCH (
            ms_file_ch.collect(),
            fasta,
            spectral_library,
            (speclib_only == true ? "subset_library" : "quant"),
            search_params
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
        diann_version
        output_file_stats
}

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

        def mbr_params = params.diann.search_params + (speclib_only == true ? " --reanalyze" : "")

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