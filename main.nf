#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// Sub workflows
include { get_input_files } from "./workflows/get_input_files"
include { encyclopedia_search as encyclopeda_export_elib } from "./workflows/encyclopedia_search"
include { encyclopedia_search as encyclopedia_quant } from "./workflows/encyclopedia_search"
include { diann_search } from "./workflows/diann_search"
include { get_mzmls as get_narrow_mzmls } from "./workflows/get_mzmls"
include { get_mzmls as get_wide_mzmls } from "./workflows/get_mzmls"
include { skyline_import } from "./workflows/skyline_import"
include { skyline_annotate_doc } from "./workflows/skyline_annotate_document"
include { skyline_reports } from "./workflows/skyline_run_reports"
include { generate_dia_qc_report } from "./workflows/generate_qc_report"
include { panorama_upload_results } from "./workflows/panorama_upload"
include { panorama_upload_mzmls } from "./workflows/panorama_upload"

// modules
include { SAVE_RUN_DETAILS } from "./modules/save_run_details"
include { ENCYCLOPEDIA_BLIB_TO_DLIB } from "./modules/encyclopedia"
include { ENCYCLOPEDIA_DLIB_TO_TSV } from "./modules/encyclopedia"
include { BLIB_BUILD_LIBRARY } from "./modules/diann"

// Check if old Skyline parameter variables are defined.
// If the old variable is defnied, return the params value of the old variable,
// otherwise return the params value of the new variable
def check_old_param_name(old_var, new_var) {
    def(section, param) = new_var.split(/\./)
    if(params[old_var] != null) {
        if(params[section][param] != null) {
            log.warn "Both params.$old_var and params.$new_var are defined!"
        }
        log.warn "Setting params.$new_var = params.$old_var"
        return params[old_var]
    }
    return params[section][param]
}

//
// The main workflow
//
workflow {

    all_mzml_ch = null       // hold all mzml files generated
    all_elib_ch = null       // hold all elibs generated by encyclopedia
    all_diann_file_ch = null // all files generated by diann to upload

    config_file = file(workflow.configFiles[1]) // the config file used

    // check for old param variable names
    params.skyline.document_name = check_old_param_name('skyline_document_name',
                                                        'skyline.document_name')
    params.skyline.skip = check_old_param_name('skip_skyline',
                                               'skyline.skip')
    params.skyline.template_file = check_old_param_name('skyline_template_file',
                                                        'skyline.template_file')
    params.skyline.skyr_file = check_old_param_name('skyline_skyr_file',
                                                    'skyline.skyr_file')

    // check for required params or incompatible params
    if(params.panorama.upload && !params.panorama.upload_url) {
        error "Panorama upload requested, but missing param: \'panorama.upload_url\'."
    }

    if(params.panorama.import_skyline) {
        if(!params.panorama.upload) {
            error "Import of Skyline document in Panorama requested, but \'panorama.upload\' is not set to true."
        }
        if(params.skyline.skip) {
            error "Import of Skyline document in Panorama requested, but \'skyline.skip\' is set to true."
        }
    }

    // save details about this run
    SAVE_RUN_DETAILS()
    run_details_file = SAVE_RUN_DETAILS.out.run_details

    // only perform msconvert and terminate
    if(params.msconvert_only) {
        get_wide_mzmls(params.quant_spectra_dir, params.quant_spectra_glob)  // get wide windows mzmls
        wide_mzml_ch = get_wide_mzmls.out.mzml_ch

        if(params.chromatogram_library_spectra_dir != null) {
            get_narrow_mzmls(params.chromatogram_library_spectra_dir,
                             params.chromatogram_library_spectra_glob)

            narrow_mzml_ch = get_narrow_mzmls.out.mzml_ch
            all_mzml_ch = wide_mzml_ch.concat(narrow_mzml_ch)
        } else {
            all_mzml_ch = wide_mzml_ch
        }

        // if requested, upload mzMLs to panorama
        if(params.panorama.upload) {

            panorama_upload_mzmls(
                params.panorama.upload_url,
                all_mzml_ch,
                run_details_file,
                config_file
            )
        }

        return
    }

    get_input_files()   // get input files
    get_wide_mzmls(params.quant_spectra_dir, params.quant_spectra_glob)  // get wide windows mzmls

    // set up some convenience variables

    if(params.spectral_library) {
        spectral_library = get_input_files.out.spectral_library
    } else {
        spectral_library = Channel.empty()
    }

    fasta = get_input_files.out.fasta
    skyline_template_zipfile = get_input_files.out.skyline_template_zipfile
    wide_mzml_ch = get_wide_mzmls.out.mzml_ch
    skyr_file_ch = get_input_files.out.skyr_files

    final_elib = null

    if(params.search_engine.toLowerCase() == 'encyclopedia') {

        if(!params.spectral_library) {
            error "The parameter \'spectral_library\' is required when using EncyclopeDIA."
        }

        all_diann_file_ch = Channel.empty()  // will be no diann

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
            // get narrow windows mzmls
            get_narrow_mzmls(params.chromatogram_library_spectra_dir,
                             params.chromatogram_library_spectra_glob)
            narrow_mzml_ch = get_narrow_mzmls.out.mzml_ch

            all_mzml_ch = wide_mzml_ch.concat(narrow_mzml_ch)

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

            all_elib_ch = encyclopeda_export_elib.out.elib.concat(
                encyclopeda_export_elib.out.individual_elibs
            )
        } else {
            quant_library = spectral_library_to_use
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

        final_elib = encyclopedia_quant.out.elib

        all_elib_ch = all_elib_ch.concat(
            encyclopedia_quant.out.individual_elibs,
            encyclopedia_quant.out.elib,
            encyclopedia_quant.out.peptide_quant,
            encyclopedia_quant.out.protein_quant
        )

    } else if(params.search_engine.toLowerCase() == 'diann') {

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


        all_elib_ch = Channel.empty()  // will be no encyclopedia
        all_mzml_ch = wide_mzml_ch

        diann_search(
            wide_mzml_ch,
            fasta,
            spectral_library_to_use
        )

        // create compatible spectral library for Skyline, if needed
        if(!params.skyline.skip) {
            BLIB_BUILD_LIBRARY(diann_search.out.speclib,
                               diann_search.out.precursor_tsv)

            final_elib = BLIB_BUILD_LIBRARY.out.blib
        } else {
            final_elib = Channel.empty()
        }

        // all files to upload to panoramaweb (if requested)
        all_diann_file_ch = diann_search.out.speclib.concat(
            diann_search.out.precursor_tsv
        ).concat(
            diann_search.out.quant_files.flatten()
        ).concat(
            final_elib
        ).concat(
            diann_search.out.stdout
        ).concat(
            diann_search.out.stderr
        ).concat(
            diann_search.out.predicted_speclib
        )

    } else {
        error "'${params.search_engine}' is an invalid argument for params.search_engine!"
    }

    if(!params.skyline.skip) {

        // create Skyline document
        if(skyline_template_zipfile != null) {
            skyline_import(
                skyline_template_zipfile,
                fasta,
                final_elib,
                wide_mzml_ch
            )
        }

        // annotate skyline document if replicate_metadata was specified
        if(params.replicate_metadata != null) {
            skyline_annotate_doc(skyline_import.out.skyline_results,
                                 get_input_files.out.replicate_metadata)
            final_skyline_file = skyline_annotate_doc.out.skyline_results
        } else {
            final_skyline_file = skyline_import.out.skyline_results
        }

        // generate QC report
        if(!params.qc_report.skip) {
            generate_dia_qc_report(final_skyline_file, get_input_files.out.replicate_metadata)
        }

        // run reports if requested
        skyline_reports_ch = null;
        if(params.skyline.skyr_file) {
            skyline_reports(
                final_skyline_file,
                skyr_file_ch
            )
            skyline_reports_ch = skyline_reports.out.skyline_report_files.flatten()
        } else {
            skyline_reports_ch = Channel.empty()
        }
    } else {

        // skip skyline
        skyline_reports_ch = Channel.empty()
        skyr_file_ch = Channel.empty()
        final_skyline_file = Channel.empty()
        qc_report_files = Channel.empty()
    }

    // upload results to Panorama
    if(params.panorama.upload) {

        panorama_upload_results(
            params.panorama.upload_url,
            all_elib_ch,
            all_diann_file_ch,
            final_skyline_file,
            all_mzml_ch,
            fasta,
            spectral_library,
            run_details_file,
            config_file,
            skyr_file_ch,
            skyline_reports_ch
        )
    }

}

/*
 * get FASTA file from either disk or Panorama
 */
def get_fasta() {
    // get files from Panorama as necessary
    if(params.fasta.startsWith("https://")) {
        PANORAMA_GET_FASTA(params.fasta)
        fasta = PANORAMA_GET_FASTA.out.panorama_file
    } else {
        fasta = file(params.fasta, checkIfExists: true)
    }

    return fasta
}


//
// Used for email notifications
//
def email() {
    // Create the email text:
    def (subject, msg) = EmailTemplate.email(workflow, params)
    // Send the email:
    if (params.email) {
        sendMail(
            to: "$params.email",
            subject: subject,
            body: msg
        )
    }
}

//
// This is a dummy workflow for testing
//
workflow dummy {
    println "This is a workflow that doesn't do anything."
}

// Email notifications:
workflow.onComplete {
    try {
        email()
    } catch (Exception e) {
        println "Warning: Error sending completion email."
    }
}
