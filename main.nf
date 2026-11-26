#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// functions for parameter validation
include { validateParameters } from 'plugin/nf-schema'

// Sub workflows
include { get_input_files } from "./subworkflows/get_input_files"
include { get_replicate_metadata } from "./subworkflows/get_replicate_metadata"
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
include { param_to_list } from "./modules/utils.nf"
include { resolve_user_path } from "./modules/utils.nf"
include { parse_batch_file } from "./modules/utils.nf"
include { validate_batch_names } from "./modules/utils.nf"
include { normalize_batch_map } from "./modules/utils.nf"
include { validate_document_name } from "./modules/utils.nf"
include { validate_batch_names_for_documents } from "./modules/utils.nf"

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

    // Slack notifications. Registered before anything that can fail, including parameter
    // validation: an error raised before a handler exists notifies no one. Both handlers
    // are needed because Nextflow versions before 25 fire only onError for a failure during
    // workflow construction. SlackNotifier makes sure one failure sends one message.
    workflow.onComplete = { slack_notify('complete') }
    workflow.onError = { slack_notify('error') }

    all_ms_file_ch = null       // hold all mzml files generated
    all_mzml_ch = null

    // Validate input parameters
    validateParameters()

    // version file channels
    search_engine_version = null
    proteowizard_version = null
    dia_qc_version = null

    config_file = file(workflow.configFiles[1]) // the config file used
    search_engine = params.search_engine == null ? 'null' : params.search_engine.toLowerCase().trim()

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

    if (params.pdc.study_id && !params.msconvert_only) {
        def normalized_engine = params.search_engine == null ? null : params.search_engine.toString().toLowerCase().trim()
        if (normalized_engine != 'diann') {
            def shown = params.search_engine == null ? "null (no-search mode)" : "'${params.search_engine}'"
            error "When using the PDC branch (params.pdc.study_id is set), params.search_engine must be 'diann'. " +
                  "Got: ${shown}.\n" +
                  "  - To run a non-DIA-NN analysis, supply MS inputs via params.quant_spectra_dir instead of params.pdc.study_id.\n" +
                  "  - To download and convert PDC files without running a search, set params.msconvert_only = true."
        }
    }

    // Demultiplexing overlapping DIA windows requires msconvert. use_vendor_raw skips
    // msconvert and hands the raw files to DIA-NN and Skyline, neither of which
    // demultiplexes them, so the two settings cannot both be set. Checked before the
    // msconvert_only guard below so a config with all three flags reports the conflict
    // that changes results, not the no-op one.
    if(params.use_vendor_raw && params.msconvert.do_demultiplex) {
        error "Parameter `msconvert.do_demultiplex` cannot be true when `use_vendor_raw` is true.\n" +
              "  Demultiplexing overlapping DIA windows requires msconvert, but use_vendor_raw feeds\n" +
              "  the vendor raw files directly to DIA-NN and Skyline, neither of which demultiplexes them.\n" +
              "  - If your DIA windows overlap (staggered windows), set use_vendor_raw = false.\n" +
              "  - If they do not overlap, set msconvert.do_demultiplex = false."
    }

    // msconvert_only exists to run msconvert; use_vendor_raw skips it, leaving nothing to do.
    if(params.msconvert_only && params.use_vendor_raw) {
        error "Parameter `msconvert_only` requires `use_vendor_raw` to be false.\n" +
              "  msconvert_only converts spectra with msconvert and exits, but use_vendor_raw\n" +
              "  skips msconvert, so no files would be converted."
    }

    // Fail fast on Carafe param-combination errors before any process runs.
    carafe_enabled()

    // if accessing panoramaweb and running on aws, set up an aws secret
    if(workflow.profile == 'aws' && is_panorama_authentication_required()) {
        GET_AWS_USER_ID()
        BUILD_AWS_SECRETS(GET_AWS_USER_ID.out)
        aws_secret_id = BUILD_AWS_SECRETS.out.aws_secret_id
    } else {
        aws_secret_id = Channel.of('none').collect()    // ensure this is a value channel
    }

    // get raw/mzML files
    use_batch_mode = params.quant_spectra_dir instanceof Map || params.pdc.batch_file != null

    // Resolve and validate batch definitions up front, before any input resolution runs, so a
    // bad batch name or malformed batch file fails before the first file is listed or converted.
    pdc_batch_map = params.pdc.batch_file == null ? null
                                                 : parse_batch_file(params.pdc.batch_file, 'pdc.batch_file')

    // Batch names are trimmed here and this one normalized value feeds both get_ms_files and
    // batch_name_list, so the two can never disagree about a batch's name.
    quant_spectra_dir = normalize_batch_map(params.quant_spectra_dir, 'quant_spectra_dir')

    // The Skyline document name becomes part of file names too, so it is checked here with
    // the batch names. It is not used when no document is made.
    if(!params.msconvert_only && !params.skyline.skip) {
        validate_document_name(params.skyline.document_name, 'skyline.document_name')

        // On PDC runs the default name 'final' is replaced by the study name. A name fetched
        // from PDC is reduced to letters and underscores by PDC_client; one taken from the
        // config (with pdc.metadata_tsv) is used as it is.
        if(params.pdc.study_id && params.pdc.metadata_tsv != null && params.skyline.document_name == 'final') {
            if(params.pdc.study_name != null) {
                validate_document_name(params.pdc.study_name, 'pdc.study_name')
            } else {
                validate_document_name(params.pdc.study_id, 'pdc.study_id')
            }
        }

        // In multi-batch mode the batch name is part of the document name
        // (<document_name>_<batch>), so it cannot contain those characters either.
        if(quant_spectra_dir instanceof Map) {
            validate_batch_names_for_documents(quant_spectra_dir.keySet(), 'quant_spectra_dir')
        }
        if(pdc_batch_map != null) {
            validate_batch_names_for_documents(pdc_batch_map.values().toList().unique(), 'pdc.batch_file')
        }
    }

    quant_spectra_file_json = Channel.empty()
    if(params.pdc.study_id) {
        get_pdc_files()
        wide_ms_file_ch = get_pdc_files.out.wide_ms_file_ch
        wide_mzml_ch = get_pdc_files.out.converted_mzml_ch
        pdc_study_name = get_pdc_files.out.study_name
        pdc_result_files = get_pdc_files.out.pdc_files
        pdc_study_metadata = get_pdc_files.out.metadata
        pdc_client_version = get_pdc_files.out.pdc_client_version
        batch_name_list = pdc_batch_map == null ? [null] : pdc_batch_map.values().toList().unique().sort()
        if(params.skyline.document_name == 'final') {
            skyline_document_name = pdc_study_name
         } else {
            skyline_document_name = Channel.value(params.skyline.document_name)
         }
    } else {
        String quant_spectra_regex = get_file_regex(
            params.quant_spectra_glob, params.quant_spectra_regex, 'quant_spectra'
        )
        get_wide_ms_files(
            quant_spectra_dir,
            quant_spectra_regex,
            params.files_per_quant_batch,
            aws_secret_id,
            allowed_ms_extensions_for_engine(params.search_engine),
            'quant_spectra_dir'
        )
        wide_ms_file_ch = get_wide_ms_files.out.ms_file_ch
        wide_mzml_ch = get_wide_ms_files.out.converted_mzml_ch
        quant_spectra_file_json = get_wide_ms_files.out.file_json
        pdc_study_name = null
        pdc_result_files = Channel.empty()
        pdc_study_metadata = Channel.empty()
        pdc_client_version = Channel.empty()
        batch_name_list = use_batch_mode ? quant_spectra_dir.collect{ k, v -> k } : [null]
        skyline_document_name = Channel.value(params.skyline.document_name)
    }

    narrow_ms_file_ch = null
    chrom_lib_file_json = null
    if(params.chromatogram_library_spectra_dir != null) {
        String chrom_lib_spectra_regex = get_file_regex(
            params.chromatogram_library_spectra_glob, params.chromatogram_library_spectra_regex,
            'chromatogram_library_spectra'
        )
        get_narrow_ms_files(
            params.chromatogram_library_spectra_dir,
            chrom_lib_spectra_regex,
            params.files_per_chrom_lib,
            aws_secret_id,
            allowed_ms_extensions_for_engine(params.search_engine),
            'chromatogram_library_spectra_dir'
        )
        narrow_ms_file_ch = get_narrow_ms_files.out.ms_file_ch
        chrom_lib_file_json = get_narrow_ms_files.out.file_json
        all_ms_file_ch = wide_ms_file_ch.concat(narrow_ms_file_ch).map{ it -> it[1] }
        all_mzml_ch = wide_mzml_ch.concat(get_narrow_ms_files.out.converted_mzml_ch)
    } else {
        chrom_lib_file_json = Channel.value("[]")
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

        // This mode never reaches the end of the workflow block, so say "started" here.
        slack_notify('start')
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
        get_replicate_metadata(
            quant_spectra_file_json,
            chrom_lib_file_json,
            aws_secret_id
        )
        replicate_metadata = get_replicate_metadata.out.validated_metadata
    }
    fasta = get_input_files.out.fasta
    skyline_template_zipfile = get_input_files.out.skyline_template_zipfile
    skyr_file_ch = get_input_files.out.skyr_files

    // Get input spectral library
    if(carafe_enabled()) {
        if(params.spectral_library) {
            log.warn "Carafe spectral library will override params.spectral_library"
        }
        // PDC-driven Carafe takes its files from the PDC download set; non-PDC modes
        // ignore this channel via carafe.nf's source-selection block.
        pdc_carafe_ch = (params.pdc.study_id && carafe_pdc_enabled())
            ? get_pdc_files.out.carafe_pdc_ms_file_ch
            : Channel.empty()
        carafe(fasta, aws_secret_id, pdc_carafe_ch)
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
        params.search_engine,
        fasta,
        spectral_library,
        narrow_ms_file_ch,
        wide_ms_file_ch,
        use_batch_mode
    )
    search_engine_version = dia_search.out.search_engine_version
    final_speclib = dia_search.out.final_speclib

    if (search_engine == 'cascadia') {
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
        use_batch_mode,
        batch_name_list
    )

    // Both are emitted by the skyline workflow but were never read back here, so they stayed
    // null from their declaration above and Channel.concat silently dropped them -- and
    // everything after them -- from the run details (audit finding C1).
    proteowizard_version = skyline.out.proteowizard_version
    dia_qc_version = skyline.out.dia_qc_version

    version_files = search_engine_version
        .concat(proteowizard_version,
                dia_qc_version,
                carafe_version,
                pdc_client_version)
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
        pdc_result_files,
        run_details_file
    )

    // upload results to Panorama
    if(params.panorama.upload) {

        // Everything a user needs to reproduce this run, uploaded to <run>/input-files.
        // The search FASTA is not used here: on Cascadia runs it is a search product, and it
        // is already uploaded to results/cascadia. What belongs here are the FASTAs the user
        // supplied -- params.fasta and, when set, params.skyline.fasta.
        panorama_input_files = get_input_files.out.fasta
            .concat(get_input_files.out.skyline_fasta)
            .unique()
            .concat(spectral_library,
                    skyr_file_ch,
                    skyline_template_zipfile)

        // The replicate metadata channel holds an empty placeholder file when no metadata was
        // supplied and the run is not a PDC study, so it is only uploaded when real metadata
        // exists. On PDC runs this is the annotations CSV generated from the study metadata.
        if(params.replicate_metadata != null || params.pdc.study_id != null) {
            panorama_input_files = panorama_input_files.concat(replicate_metadata)
        }

        // Study metadata fetched from the PDC API is the record of which files this run
        // downloaded, and a study's file set can change over time. It is published locally
        // only, so without this it is uploaded nowhere. When pdc.metadata_tsv was supplied
        // instead, that file is the metadata and is uploaded just below.
        if(params.pdc.study_id != null && params.pdc.metadata_tsv == null) {
            panorama_input_files = panorama_input_files.concat(pdc_study_metadata)
        }

        // PDC inputs the user authored, which shape the run but are not otherwise uploaded.
        // pdc.metadata_tsv is only included when the user supplied one; when it is null the
        // study metadata is fetched from PDC and is reproducible from pdc.study_id alone.
        ['pdc.batch_file': params.pdc.batch_file,
         'pdc.gene_level_data': params.pdc.gene_level_data,
         'pdc.metadata_tsv': params.pdc.metadata_tsv].each { label, value ->
            if(value != null) {
                panorama_input_files = panorama_input_files.concat(
                    Channel.value(resolve_user_path(value, label)))
            }
        }

        panorama_upload_results(
            params.panorama.upload_url,
            dia_search.out.all_search_files,
            search_engine,
            skyline.out.final_skyline_file,
            all_mzml_ch,
            panorama_input_files,
            config_file,
            run_details_file,
            combine_file_hashes.out.output_file_hashes,
            skyline.out.skyline_reports_ch,
            skyline.out.gene_reports,
            use_batch_mode,
            aws_secret_id
        )
    }

    // Email notifications
    workflow.onComplete = {
        try {
            email()
        } catch (Exception e) {
            println "Warning: Error sending completion email."
        }
    }

    // Keep this the last statement of the workflow. Every parameter check above, here and in
    // the subworkflows, has passed by now, so a bad config produces a single "failed" message
    // rather than "started" followed by "failed". The msconvert_only branch returns early and
    // makes the same call just before it does.
    slack_notify('start')
}

// Convert a Nextflow-style glob (only * is a wildcard) into a regex string
def escape_regex(String str) {
    return str.replaceAll(/([.\^$+?{}\[\]\\|()])/) { match, group -> '\\' + group }
}

// Return a regex string for matching files based on glob or regex parameters
// Also check that only one of the two parameters is set
def get_file_regex(String file_glob_param, String file_regex_param, String name) {
    if (file_glob_param != null && file_regex_param != null) {
        error "Either params.${name}_glob or params.${name}_regex can be set, but not both."
    }
    if (file_regex_param != null) {
        return file_regex_param
    } else if (file_glob_param != null) {
        return '^' + escape_regex(file_glob_param).replaceAll('\\*', '.*') + '$'
    } else {
        error "Neither params.${name}_glob nor params.${name}_regex is set."
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
           (params.carafe.spectra_file && panorama_auth_required_for_url(params.carafe.spectra_file)) ||
           (params.carafe.spectra_dir && any_entry_requires_panorama_auth(params.carafe.spectra_dir)) ||
           (params.skyline.skyr_file && any_entry_requires_panorama_auth(params.skyline.skyr_file))

}

// Allowed MS-input extensions for the chosen search engine. EncyclopeDIA and Cascadia
// cannot read Bruker .d directories, so .d.zip and pre-extracted .d are excluded for those
// engines. msconvert_only runs no search and accepts any supported input. The 'd' entry is
// a local-only, pre-extracted Bruker .d directory (enforced in get_ms_files).
def allowed_ms_extensions_for_engine(search_engine) {
    if (params.msconvert_only) {
        return ['raw', 'mzML', 'd.zip', 'd']
    }
    def normalized = search_engine == null ? null : search_engine.toString().toLowerCase().trim()
    if (normalized == 'encyclopedia' || normalized == 'cascadia') {
        return ['raw', 'mzML']
    }
    return ['raw', 'mzML', 'd.zip', 'd']
}

def carafe_pdc_enabled() {
    return params.carafe.pdc_files != null || params.carafe.pdc_n_files != null
}

def carafe_enabled() {
    def sources = [
        'carafe.spectra_file': params.carafe.spectra_file != null,
        'carafe.spectra_dir':  params.carafe.spectra_dir  != null,
        'carafe.pdc_files':    params.carafe.pdc_files    != null,
        'carafe.pdc_n_files':  params.carafe.pdc_n_files  != null,
    ]
    def active = sources.findAll { k, v -> v }.collect { k, v -> k }
    if (active.size() > 1) {
        error "Only one Carafe input source may be set, found: ${active.join(', ')}.\n" +
              "  - carafe.spectra_file and carafe.spectra_dir are mutually exclusive.\n" +
              "  - carafe.pdc_files and carafe.pdc_n_files are mutually exclusive with each other and with carafe.spectra_file/carafe.spectra_dir."
    }
    if (carafe_pdc_enabled() && !params.pdc.study_id) {
        error "params.carafe.pdc_files / params.carafe.pdc_n_files require params.pdc.study_id to also be set."
    }
    if (params.carafe.pdc_n_files != null && params.pdc.n_raw_files != null &&
            params.carafe.pdc_n_files > params.pdc.n_raw_files) {
        error "params.carafe.pdc_n_files (${params.carafe.pdc_n_files}) must be <= params.pdc.n_raw_files (${params.pdc.n_raw_files})."
    }
    return active.size() == 1
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
// Used for Slack notifications. stage is 'start', 'complete' or 'error'.
//
// A Slack problem must never fail the run, so everything is inside the try, including the
// parameter and secret lookups, and any problem is logged as a warning. The argument is
// untyped on purpose: Nextflow 24.04 rejects a GString passed to a String-typed parameter of
// a script function.
//
def slack_notify(stage) {
    try {
        if (params.slack?.enabled != true) {
            return
        }
        def warning = SlackNotifier.notify(stage.toString(), workflow, secrets.SLACK_WEBHOOK_URL?.toString())
        if (warning) {
            log.warn warning.toString()
        }
    } catch (Throwable t) {
        log.warn "Slack notification was not sent: ${t.getClass().simpleName}. The workflow is not affected."
    }
}

//
// This is a dummy workflow for testing
//
workflow dummy {
    println "This is a workflow that doesn't do anything."
}
