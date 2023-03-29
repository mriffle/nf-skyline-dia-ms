#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// Sub workflows
include { get_input_files } from "./workflows/get_input_files"
include { encyclopeda_export_elib } from "./workflows/encyclopedia_elib"
include { get_narrow_mzmls } from "./workflows/get_narrow_mzmls"

//
// The main workflow
//
workflow {

    get_input_files()   // get input files
    get_narrow_mzmls()  // get narrow windows mzmls

    fasta = get_input_files.out.fasta
    dlib = get_input_files.out.dlib
    narrow_mzml_ch = get_narrow_mzmls.out.narrow_mzml_ch

    encyclopeda_export_elib(
        narrow_mzml_ch, 
        fasta, 
        dlib
    )

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
workflow.onComplete { email() }
