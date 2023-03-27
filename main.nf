#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// modules
include { PANORAMA_GET_FASTA } from "./modules/panorama"
include { PANORAMA_GET_SPECTRAL_LIBRARY } from "./modules/panorama"
include { PANORAMA_GET_RAW_FILE } from "./modules/panorama"
include { PANORAMA_GET_RAW_FILE_LIST } from "./modules/panorama"

// Sub workflows
include { encyclopeda_search_quant } from "./workflows/encyclopeda_search_quant"

//
// The main workflow
//
workflow {

    // get files from Panorama as necessary
    if(params.fasta.startsWith("https://")) {
        PANORAMA_GET_FASTA(params.fasta)
        fasta = PANORAMA_GET_FASTA.out.panorama_file
    } else {
        fasta = file(params.fasta, checkIfExists: true)
    }

    if(params.spectral_library.startsWith("https://")) {
        PANORAMA_GET_SPECTRAL_LIBRARY(params.spectral_library)
        spectral_library = PANORAMA_GET_SPECTRAL_LIBRARY.out.panorama_file
    } else {
        spectral_library = file(params.fasta, checkIfExists: true)
    }

    if(params.spectra_dir.contains("https://")) {

        spectra_dirs_ch = Channel.from(params.spectra_dir)
                                .splitText()               // split multiline input
                                .map{ it.trim() }          // removing surrounding whitespace
                                .filter{ it.length() > 0 } // skip empty lines

        // get raw files from panorama
        PANORAMA_GET_RAW_FILE_LIST(spectra_dirs_ch)
        placeholder_ch = PANORAMA_GET_RAW_FILE_LIST.out.raw_file_placeholders.transpose()
        PANORAMA_GET_RAW_FILE(placeholder_ch)
        
        spectra_files_ch = PANORAMA_GET_RAW_FILE.out.panorama_file
        from_raw_files = true;

    } else {

        spectra_dir = file(params.spectra_dir, checkIfExists: true)

        // get our mzML files
        mzml_files = file("$spectra_dir/*.mzML")

        // get our raw files
        raw_files = file("$spectra_dir/*.raw")

        if(mzml_files.size() < 1 && raw_files.size() < 1) {
            error "No raw or mzML files found in: $spectra_dir"
        }

        if(mzml_files.size() > 0) {
                spectra_files_ch = Channel.fromList(mzml_files)
                from_raw_files = false;
        } else {
                spectra_files_ch = Channel.fromList(raw_files)
                from_raw_files = true;
        }
    }

    encyclopeda_search_quant(
        spectra_files_ch, 
        fasta, 
        spectral_library, 
        from_raw_files, 
        params.do_demultiplex, 
        params.do_simasspectra
    )

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
