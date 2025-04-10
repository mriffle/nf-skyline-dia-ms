// modules
include { CARAFE } from "../modules/carafe"

workflow run_carafe {

    take:
        mzml_file_ch
        fasta_file
        peptide_results_file
        carafe_params
        output_format

    main:
        carafe_results = CARAFE(
            mzml_file_ch,
            fasta_file,
            peptide_results_file,
            carafe_params,
            output_format
        )

    emit:
        carafe_version    = carafe_results.version
        speclib_tsv       = carafe_results.speclib_tsv
        stdout            = carafe_results.stdout
        stderr            = carafe_results.stderr
}