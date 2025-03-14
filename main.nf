#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// Sub workflows
include { get_input_files } from "./subworkflows/get_input_files"
include { get_mzmls as get_narrow_mzmls } from "./subworkflows/get_mzmls"
include { get_mzmls as get_wide_mzmls } from "./subworkflows/get_mzmls"
include { dia_search } from "./workflows/dia_search"
include { skyline } from "./workflows/skyline"
include { panorama_upload_results } from "./subworkflows/panorama_upload"
include { panorama_upload_mzmls } from "./subworkflows/panorama_upload"
include { save_run_details } from "./subworkflows/save_run_details"
include { get_pdc_files } from "./subworkflows/get_pdc_files"
include { combine_file_hashes } from "./subworkflows/combine_file_hashes"

// modules
include { GET_AWS_USER_ID } from "./modules/aws"
include { BUILD_AWS_SECRETS } from "./modules/aws"

// useful functions and variables
include { param_to_list } from "./subworkflows/get_input_files"

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

    // version file channels
    search_engine_version = null
    proteowizard_version = null
    dia_qc_version = null

    config_file = file(workflow.configFiles[1]) // the config file used
    search_engine = params.search_engine.toLowerCase().trim()

    // check for old param variable names
    params.skyline.document_name = check_old_param_name('skyline_document_name',
                                                        'skyline.document_name')
    skyline_document_name = params.skyline.document_name
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

    // if accessing panoramaweb and running on aws, set up an aws secret
    if(workflow.profile == 'aws' && is_panorama_authentication_required()) {
        GET_AWS_USER_ID()
        BUILD_AWS_SECRETS(GET_AWS_USER_ID.out)
        aws_secret_id = BUILD_AWS_SECRETS.out.aws_secret_id
    } else {
        aws_secret_id = Channel.of('none').collect()    // ensure this is a value channel
    }

    // get mzML files
    if(params.pdc.study_id) {
        get_pdc_files()
        wide_mzml_ch = get_pdc_files.out.wide_mzml_ch
        pdc_study_name = get_pdc_files.out.study_name
        skyline_document_name = skyline_document_name == 'final' ? pdc_study_name : skyline_document_name
    } else{
        get_wide_mzmls(params.quant_spectra_dir, params.quant_spectra_glob, aws_secret_id)
        wide_mzml_ch = get_wide_mzmls.out.mzml_ch
        pdc_study_name = null
    }
    narrow_mzml_ch = null
    if(params.chromatogram_library_spectra_dir != null) {
        get_narrow_mzmls(params.chromatogram_library_spectra_dir,
                         params.chromatogram_library_spectra_glob,
                         aws_secret_id)

        narrow_mzml_ch = get_narrow_mzmls.out.mzml_ch
        all_mzml_ch = wide_mzml_ch.concat(narrow_mzml_ch)
    } else {
        all_mzml_ch = wide_mzml_ch
    }

    // only perform msconvert and terminate
    if(params.msconvert_only) {

        // save details about this run
        input_files = all_mzml_ch.map{ it -> ['Spectra File', it.baseName] }
        version_files = Channel.empty()
        save_run_details(input_files.collect(), version_files.collect())
        run_details_file = save_run_details.out.run_details

        // if requested, upload mzMLs to panorama
        if(params.panorama.upload) {
            panorama_upload_mzmls(
                params.panorama.upload_url,
                all_mzml_ch,
                run_details_file,
                config_file,
                aws_secret_id
            )
        }

        return
    }

    get_input_files(aws_secret_id)   // get input files

    // set up some convenience variables
    if(params.spectral_library) {
        spectral_library = get_input_files.out.spectral_library
    } else {
        spectral_library = Channel.empty()
    }
    if(params.pdc.study_id) {
        if(params.replicate_metadata) {
            log.warn "params.replicate_metadata will be overritten by PDC metadata"
        }
        replicate_metadata = get_pdc_files.out.annotations_csv
    } else {
        replicate_metadata = get_input_files.out.replicate_metadata
    }
    fasta = get_input_files.out.fasta
    skyline_fasta = get_input_files.out.skyline_fasta
    skyline_template_zipfile = get_input_files.out.skyline_template_zipfile
    skyr_file_ch = get_input_files.out.skyr_files

    dia_search(
        search_engine,
        fasta,
        spectral_library,
        narrow_mzml_ch,
        wide_mzml_ch,
    )
    search_engine_version = dia_search.out.search_engine_version
    final_speclib = dia_search.out.final_speclib
    fasta = dia_search.out.search_fasta

    skyline (
        wide_mzml_ch,
        skyline_template_zipfile,
        skyline_fasta,
        replicate_metadata,
        skyline_document_name,
        final_speclib,
        pdc_study_name,
        skyr_file_ch
    )

    version_files = search_engine_version
        .concat(proteowizard_version,
                dia_qc_version).splitText()

    input_files = fasta.map{ it -> ['Fasta file', it.name] }.concat(
        fasta.map{ it -> ['Skyline fasta file', it.name] },
        spectral_library.map{ it -> ['Spectra library', it.baseName] },
        all_mzml_ch.map{ it -> ['Spectra file', it.baseName] })

    save_run_details(input_files.collect(), version_files.collect())
    run_details_file = save_run_details.out.run_details

    fasta_files = fasta.concat(skyline_fasta).unique()
    combine_file_hashes(fasta_files, spectral_library,
                        dia_search.out.search_file_stats,
                        skyline.out.final_skyline_file,
                        skyline.out.final_skyline_hash,
                        skyline.out.skyline_reports_ch,
                        skyline.out.qc_report_files,
                        skyline.out.gene_reports,
                        run_details_file)

    // upload results to Panorama
    if(params.panorama.upload) {

        panorama_upload_results(
            params.panorama.upload_url,
            dia_search.out.all_search_files,
            search_engine,
            skyline.out.final_skyline_file,
            all_mzml_ch,
            fasta,
            spectral_library,
            run_details_file,
            config_file,
            skyr_file_ch,
            skyline.out.skyline_reports_ch,
            aws_secret_id
        )
    }

}

// return true if the URL requires panorama authentication (panorama public does not)
def panorama_auth_required_for_url(url) {
    return url.startsWith(params.panorama.domain) && !url.contains("/_webdav/Panorama%20Public/")
}

// return true if any entry in the list required panorama authentication
def any_entry_requires_panorama_auth(param) {
    def values = param_to_list(param)
    return values.any { panorama_auth_required_for_url(it) }
}

// return true if panoramaweb authentication will be required by this workflow run
def is_panorama_authentication_required() {

    return params.panorama.upload ||
           (params.fasta && panorama_auth_required_for_url(params.fasta)) ||
           (params.skyline.fasta && panorama_auth_required_for_url(params.skyline.fasta)) ||
           (params.spectral_library && panorama_auth_required_for_url(params.spectral_library)) ||
           (params.replicate_metadata && panorama_auth_required_for_url(params.replicate_metadata)) ||
           (params.skyline.template_file && panorama_auth_required_for_url(params.skyline.template_file)) ||
           (params.quant_spectra_dir && any_entry_requires_panorama_auth(params.quant_spectra_dir)) ||
           (params.chromatogram_library_spectra_dir && any_entry_requires_panorama_auth(params.chromatogram_library_spectra_dir)) ||
           (params.skyline_skyr_file && any_entry_requires_panorama_auth(params.skyline_skyr_file))

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
