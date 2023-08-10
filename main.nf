#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// Sub workflows
include { get_input_files } from "./workflows/get_input_files"
include { encyclopeda_export_elib } from "./workflows/encyclopedia_elib"
include { encyclopedia_quant } from "./workflows/encyclopedia_quant"
include { get_narrow_mzmls } from "./workflows/get_narrow_mzmls"
include { get_wide_mzmls } from "./workflows/get_wide_mzmls"
include { skyline_import } from "./workflows/skyline_import"

// modules
include { ENCYCLOPEDIA_BLIB_TO_DLIB } from "./modules/encyclopedia"

//
// The main workflow
//
workflow {

    // only perform msconvert and terminate
    if(params.msconvert_only) {
        get_wide_mzmls()  // get wide windows mzmls
        if(params.chromatogram_library_spectra_dir != null) {
            get_narrow_mzmls()
        }
        return
    }

    get_input_files()   // get input files
    get_wide_mzmls()  // get wide windows mzmls

    // set up some convenience variables
    fasta = get_input_files.out.fasta
    spectral_library = get_input_files.out.spectral_library
    skyline_template_zipfile = get_input_files.out.skyline_template_zipfile
    wide_mzml_ch = get_wide_mzmls.out.wide_mzml_ch

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
        get_narrow_mzmls()  // get narrow windows mzmls
        narrow_mzml_ch = get_narrow_mzmls.out.narrow_mzml_ch

        // create chromatogram library
        encyclopeda_export_elib(
            narrow_mzml_ch, 
            fasta, 
            spectral_library_to_use
        )

        quant_library = encyclopeda_export_elib.out.elib
    } else {
        quant_library = spectral_library_to_use
    }

    // search wide-window data using chromatogram library
    encyclopedia_quant(
        wide_mzml_ch, 
        fasta, 
        quant_library
    )

    final_elib = encyclopedia_quant.out.final_elib

    // create Skyline document
    if(skyline_template_zipfile != null) {
        skyline_import(
            skyline_template_zipfile,
            fasta,
            final_elib,
            wide_mzml_ch
        )
    }

    // upload results to Panorama


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
