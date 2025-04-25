#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// Sub workflows
include { get_input_files } from "./subworkflows/get_input_files"
include { get_ms_files as get_narrow_ms_files } from "./subworkflows/get_ms_files"
include { get_ms_files as get_wide_ms_files } from "./subworkflows/get_ms_files"
include { carafe } from "./workflows/carafe"
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

// check for old param variable names
params.skyline.document_name = check_old_param_name('skyline_document_name',
                                                    'skyline.document_name')
params.skyline.skip = check_old_param_name('skip_skyline',
                                            'skyline.skip')
params.skyline.template_file = check_old_param_name('skyline_template_file',
                                                    'skyline.template_file')
params.skyline.skyr_file = check_old_param_name('skyline_skyr_file',
                                                'skyline.skyr_file')

//
// The main workflow
//
workflow {

    all_ms_file_ch = null       // hold all mzml files generated
    all_mzml_ch = null

    // version file channels
    search_engine_version = null
    proteowizard_version = null
    dia_qc_version = null

    config_file = file(workflow.configFiles[1]) // the config file used
    search_engine = params.search_engine.toLowerCase().trim()

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
    use_batch_mode = params.quant_spectra_dir instanceof Map
    if(params.pdc.study_id) {
        get_pdc_files()
        wide_ms_file_ch = get_pdc_files.out.wide_ms_file_ch
        wide_mzml_ch = get_pdc_files.out.wide_ms_file_ch
        pdc_study_name = get_pdc_files.out.study_name
        if(params.skyline.document_name == 'final') {
            skyline_document_name = pdc_study_name
         } else {
            skyline_document_name = Channel.value(params.skyline.document_name)
         }
    } else {
        get_wide_ms_files(params.quant_spectra_dir,
                          params.quant_spectra_glob,
                          params.files_per_quant_batch,
                          aws_secret_id)
        wide_ms_file_ch = get_wide_ms_files.out.ms_file_ch
        wide_mzml_ch = get_wide_ms_files.out.converted_mzml_ch
        pdc_study_name = null
        skyline_document_name = Channel.value(params.skyline.document_name)
    }
    narrow_ms_file_ch = null
    if(params.chromatogram_library_spectra_dir != null) {
        get_narrow_ms_files(params.chromatogram_library_spectra_dir,
                            params.chromatogram_library_spectra_glob,
                            params.files_per_chrom_lib,
                            aws_secret_id)

        narrow_ms_file_ch = get_narrow_ms_files.out.ms_file_ch
        all_ms_file_ch = wide_ms_file_ch.concat(narrow_ms_file_ch).map{ it -> it[1] }
        all_mzml_ch = wide_mzml_ch.concat(get_narrow_ms_files.out.converted_mzml_ch)
    } else {
        all_ms_file_ch = wide_ms_file_ch.map{ it -> it[1] }
        all_mzml_ch = wide_mzml_ch
    }

    // only perform msconvert and terminate
    if(params.msconvert_only) {

        // save details about this run
        input_files = all_ms_file_ch.map{ it -> ['Spectra File', it.baseName] }
        version_files = Channel.empty()
        save_run_details(input_files.collect(), version_files.collect())
        run_details_file = save_run_details.out.run_details

        // if requested, upload mzMLs to panorama
        if(params.panorama.upload) {
            panorama_upload_mzmls(
                params.panorama.upload_url,
                all_ms_file_ch,
                run_details_file,
                config_file,
                aws_secret_id
            )
        }

        return
    }

    get_input_files(aws_secret_id)   // get input files

    // set up some convenience variables
    if(params.pdc.study_id) {
        if(params.replicate_metadata) {
            log.warn "PDC metadata will override params.replicate_metadata"
        }
        replicate_metadata = get_pdc_files.out.annotations_csv
    } else {
        replicate_metadata = get_input_files.out.replicate_metadata
    }
    fasta = get_input_files.out.fasta
    skyline_template_zipfile = get_input_files.out.skyline_template_zipfile
    skyr_file_ch = get_input_files.out.skyr_files

    // Get input spectral library
    if(params.carafe.spectra_file != null) {
        if(params.spectral_library) {
            log.warn "Carafe spectral library will override params.spectral_library"
        }
        carafe(fasta, aws_secret_id)
        spectral_library = carafe.out.spectral_library
        carafe_version = carafe.out.carafe_version
    }
    else if(params.spectral_library) {
        spectral_library = get_input_files.out.spectral_library
        carafe_version = Channel.empty()
    } else {
        spectral_library = Channel.empty()
        carafe_version = Channel.empty()
    }

    dia_search(
        search_engine,
        fasta,
        spectral_library,
        narrow_ms_file_ch,
        wide_ms_file_ch,
        use_batch_mode
    )
    search_engine_version = dia_search.out.search_engine_version
    final_speclib = dia_search.out.final_speclib

    if (params.search_engine.toLowerCase() == 'cascadia') {
        // Always use fasta generated by Cascadia search for Skyline
        skyline_fasta = dia_search.out.search_fasta
    } else {
        skyline_fasta = get_input_files.out.skyline_fasta
    }

    skyline (
        wide_ms_file_ch,
        skyline_template_zipfile,
        skyline_fasta,
        replicate_metadata,
        skyline_document_name,
        final_speclib,
        pdc_study_name,
        skyr_file_ch,
        use_batch_mode
    )

    version_files = search_engine_version
        .concat(proteowizard_version,
                dia_qc_version,
                carafe_version)
        .splitText()

    input_files = fasta
        .map{ it -> ['Fasta file', it.name] }
        .concat(
            skyline_fasta.map{ it -> ['Skyline fasta file', it.name] },
            spectral_library.map{ it -> ['Spectra library', it.baseName] },
            all_ms_file_ch.map{ it -> ['Spectra file', it.baseName] }
        )

    save_run_details(input_files.collect(), version_files.collect())
    run_details_file = save_run_details.out.run_details

    fasta_files = fasta.concat(skyline_fasta).unique()
    combine_file_hashes(
        fasta_files, spectral_library,
        dia_search.out.search_file_stats,
        skyline.out.final_skyline_file,
        skyline.out.final_skyline_hash,
        skyline.out.skyline_reports_ch,
        skyline.out.qc_report_files,
        skyline.out.gene_reports,
        run_details_file
    )

    // upload results to Panorama
    if(params.panorama.upload) {

        panorama_upload_results(
            params.panorama.upload_url,
            dia_search.out.all_search_files,
            search_engine,
            skyline.out.final_skyline_file,
            all_mzml_ch,
            dia_search.out.search_fasta,
            spectral_library,
            config_file,
            run_details_file,
            combine_file_hashes.out.output_file_hashes,
            skyr_file_ch,
            skyline.out.skyline_reports_ch,
            use_batch_mode,
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

def any_map_entry_requires_panorama_auth(param) {
    if(param instanceof Map){
        println('Instance of Map!')
        return param.any{ k, v -> any_entry_requires_panorama_auth(v) }
    }
    return any_entry_requires_panorama_auth(param)
}

// return true if panoramaweb authentication will be required by this workflow run
def is_panorama_authentication_required() {

    return params.panorama.upload ||
           (params.fasta && panorama_auth_required_for_url(params.fasta)) ||
           (params.skyline.fasta && panorama_auth_required_for_url(params.skyline.fasta)) ||
           (params.spectral_library && panorama_auth_required_for_url(params.spectral_library)) ||
           (params.replicate_metadata && panorama_auth_required_for_url(params.replicate_metadata)) ||
           (params.skyline.template_file && panorama_auth_required_for_url(params.skyline.template_file)) ||
           (params.quant_spectra_dir && any_map_entry_requires_panorama_auth(params.quant_spectra_dir)) ||
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
