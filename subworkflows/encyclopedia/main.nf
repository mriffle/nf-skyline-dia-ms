
include { encyclopedia_search as encyclopeda_export_elib } from "./encyclopedia_search"
include { encyclopedia_search as encyclopedia_quant } from "./encyclopedia_search"
include { ENCYCLOPEDIA_BLIB_TO_DLIB } from "../../modules/encyclopedia"
include { ENCYCLOPEDIA_DLIB_TO_TSV } from "../../modules/encyclopedia"

workflow encyclopedia {
    take:
        fasta
        spectral_library
        narrow_mzml_ch
        wide_mzml_ch

    main:
        if(!params.spectral_library) {
            error "The parameter \'spectral_library\' is required when using EncyclopeDIA."
        }

        if(!params.fasta) {
            error "The parameter \'fasta\' is required when using EncyclopeDIA."
        }


        // convert blib to dlib if necessary
        if(params.spectral_library.endsWith(".blib")) {
            ENCYCLOPEDIA_BLIB_TO_DLIB(
                fasta,
                spectral_library
            )

            spectral_library_to_use = ENCYCLOPEDIA_BLIB_TO_DLIB.out.dlib
        } else {
            spectral_library_to_use = spectral_library
        }

        // create elib if requested
        if(params.chromatogram_library_spectra_dir != null) {

            // create chromatogram library
            encyclopeda_export_elib(
                narrow_mzml_ch,
                fasta,
                spectral_library_to_use,
                'false',
                'narrow',
                params.encyclopedia.chromatogram.params
            )

            quant_library = encyclopeda_export_elib.out.elib
            spec_lib_hashes = encyclopeda_export_elib.out.output_file_stats

            all_elib_ch = encyclopeda_export_elib.out.elib.concat(
                encyclopeda_export_elib.out.individual_elibs
            )
            quant_library = spectral_library_to_use
            spec_lib_hashes = Channel.empty()
            all_mzml_ch = wide_mzml_ch
            all_elib_ch = Channel.empty()
        }

        // search wide-window data using chromatogram library
        encyclopedia_quant(
            wide_mzml_ch,
            fasta,
            quant_library,
            'true',
            'wide',
            params.encyclopedia.quant.params
        )

        all_elib_ch = all_elib_ch.concat(
            encyclopedia_quant.out.individual_elibs,
            encyclopedia_quant.out.elib,
            encyclopedia_quant.out.peptide_quant,
            encyclopedia_quant.out.protein_quant
        )

    emit:
        final_elib = encyclopedia_quant.out.elib
        version = encyclopedia_quant.out.encyclopedia_version
        search_file_stats = encyclopedia_quant.out.output_file_stats.concat(spec_lib_hashes)
        all_elib_ch = all_elib_ch
}