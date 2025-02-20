#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// Sub workflows
include { get_input_files } from "./workflows/get_input_files"
include { encyclopedia_search as encyclopeda_export_elib } from "./workflows/encyclopedia_search"
include { encyclopedia_search as encyclopedia_quant } from "./workflows/encyclopedia_search"
include { diann_search } from "./workflows/diann_search"
include { cascadia_search } from "./workflows/cascadia_search"
include { get_mzmls as get_narrow_mzmls } from "./workflows/get_mzmls"
include { get_mzmls as get_wide_mzmls } from "./workflows/get_mzmls"
include { skyline_import } from "./workflows/skyline_import"
include { skyline_reports } from "./workflows/skyline_run_reports"
include { generate_dia_qc_report } from "./workflows/generate_qc_report"
include { panorama_upload_results } from "./workflows/panorama_upload"
include { panorama_upload_mzmls } from "./workflows/panorama_upload"
include { save_run_details } from "./workflows/save_run_details"
include { get_pdc_files } from "./workflows/get_pdc_files"
include { combine_file_hashes } from "./workflows/combine_file_hashes"

// modules
include { ENCYCLOPEDIA_BLIB_TO_DLIB } from "./modules/encyclopedia"
include { ENCYCLOPEDIA_DLIB_TO_TSV } from "./modules/encyclopedia"
include { BLIB_BUILD_LIBRARY } from "./modules/diann"
include { GET_AWS_USER_ID } from "./modules/aws"
include { BUILD_AWS_SECRETS } from "./modules/aws"
include { EXPORT_GENE_REPORTS } from "./modules/qc_report"

// useful functions and variables
include { param_to_list } from "./workflows/get_input_files"

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

    // version file channles
    encyclopedia_version = null
    diann_version = null
    proteowizard_version = null
    dia_qc_version = null

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
    } else{
        get_wide_mzmls(params.quant_spectra_dir, params.quant_spectra_glob, aws_secret_id)
        wide_mzml_ch = get_wide_mzmls.out.mzml_ch
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
    skyline_template_zipfile = get_input_files.out.skyline_template_zipfile
    skyr_file_ch = get_input_files.out.skyr_files

    final_elib = null

    if(params.search_engine.toLowerCase() == 'encyclopedia') {

        if(!params.spectral_library) {
            error "The parameter \'spectral_library\' is required when using EncyclopeDIA."
        }

        if(!params.fasta) {
            error "The parameter \'fasta\' is required when using EncyclopeDIA."
        }

        all_diann_file_ch = Channel.empty()  // will be no diann
        diann_version = Channel.empty()

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
        } else {
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

        encyclopedia_version = encyclopedia_quant.out.encyclopedia_version
        search_file_stats = encyclopedia_quant.out.output_file_stats.concat(spec_lib_hashes)

        final_elib = encyclopedia_quant.out.elib
        all_elib_ch = all_elib_ch.concat(
            encyclopedia_quant.out.individual_elibs,
            encyclopedia_quant.out.elib,
            encyclopedia_quant.out.peptide_quant,
            encyclopedia_quant.out.protein_quant
        )

    } else if(params.search_engine.toLowerCase() == 'diann') {

        if(!params.fasta) {
            error "The parameter \'fasta\' is required when using diann."
        }

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
        encyclopedia_version = Channel.empty()
        all_mzml_ch = wide_mzml_ch

        diann_search(
            wide_mzml_ch,
            fasta,
            spectral_library_to_use
        )

        diann_version = diann_search.out.diann_version
        search_file_stats = diann_search.out.output_file_stats

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
    } else if(params.search_engine.toLowerCase() == 'cascadia') {

        if (params.spectral_library != null) {
            log.warn "The parameter 'spectral_library' is set to a value (${params.spectral_library}) but will be ignored."
        }

        all_elib_ch = Channel.empty()  // will be no encyclopedia
        all_diann_file_ch = Channel.empty() // will be no diann
        encyclopedia_version = Channel.empty()
        diann_version = Channel.empty()

        all_mzml_ch = wide_mzml_ch

        cascadia_search(
            wide_mzml_ch
        )

        cascadia_version = cascadia_search.out.cascadia_version
        search_file_stats = cascadia_search.out.output_file_stats
        final_elib = cascadia_search.out.blib
        fasta = cascadia_search.out.fasta

        // all files to upload to panoramaweb (if requested)
        all_cascadia_file_ch = cascadia_search.out.blib.concat(
            cascadia_search.out.fasta
        ).concat(
            cascadia_search.out.stdout
        ).concat(
            cascadia_search.out.stderr
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
                wide_mzml_ch,
                replicate_metadata
            )
            proteowizard_version = skyline_import.out.proteowizard_version
        }

        final_skyline_file = skyline_import.out.skyline_results
        final_skyline_hash = skyline_import.out.skyline_results_hash

        // generate QC report
        if(!params.qc_report.skip) {
            generate_dia_qc_report(final_skyline_file, replicate_metadata)
            dia_qc_version = generate_dia_qc_report.out.dia_qc_version
            qc_report_files = generate_dia_qc_report.out.qc_reports.concat(
                generate_dia_qc_report.out.qc_report_qmd,
                generate_dia_qc_report.out.qc_report_db,
                generate_dia_qc_report.out.qc_tables
            )

            // Export PDC gene tables
            if(params.pdc.gene_level_data != null) {
                gene_level_data = file(params.pdc.gene_level_data, checkIfExists: true)
                EXPORT_GENE_REPORTS(generate_dia_qc_report.out.qc_report_db,
                                    gene_level_data,
                                    pdc_study_name)
                EXPORT_GENE_REPORTS.out.gene_reports | flatten | set{ gene_reports }
            } else {
                gene_reports = Channel.empty()
            }
        } else {
            dia_qc_version = Channel.empty()
            qc_report_files = Channel.empty()
            gene_reports = Channel.empty()
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
        proteowizard_version = Channel.empty()
        final_skyline_hash = Channel.empty()
        dia_qc_version = Channel.empty()
        gene_reports = Channel.empty()
    }

    version_files = encyclopedia_version.concat(diann_version,
                                                proteowizard_version,
                                                cascadia_version,
                                                dia_qc_version).splitText()

    input_files = fasta.map{ it -> ['Fasta file', it.name] }.concat(
        spectral_library.map{ it -> ['Spectra library', it.baseName] },
        all_mzml_ch.map{ it -> ['Spectra file', it.baseName] })

    save_run_details(input_files.collect(), version_files.collect())
    run_details_file = save_run_details.out.run_details

    combine_file_hashes(fasta, spectral_library,
                        search_file_stats,
                        final_skyline_file,
                        final_skyline_hash,
                        skyline_reports_ch,
                        qc_report_files,
                        gene_reports,
                        run_details_file)

    // upload results to Panorama
    if(params.panorama.upload) {

        panorama_upload_results(
            params.panorama.upload_url,
            all_elib_ch,
            all_diann_file_ch,
            all_cascadia_file_ch,
            final_skyline_file,
            all_mzml_ch,
            fasta,
            spectral_library,
            run_details_file,
            config_file,
            skyr_file_ch,
            skyline_reports_ch,
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
    values = param_to_list(param)
    return values.any { panorama_auth_required_for_url(it) }
}

// return true if panoramaweb authentication will be required by this workflow run
def is_panorama_authentication_required() {

    return params.panorama.upload ||
           (params.fasta && panorama_auth_required_for_url(params.fasta)) ||
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
