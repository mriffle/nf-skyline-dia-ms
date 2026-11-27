
/**
* Process a parameter variable which is specified as either a single value or List.
* If param_variable has multiple lines, each line with text is returned as an
* element in a List.
*
* @param param_variable A parameter variable which can either be a single value or List.
* @return param_variable as a List with 1 or more values.
*/
def param_to_list(param_variable) {
    if(param_variable instanceof List) {
        return param_variable
    }
    if(param_variable instanceof String) {
        // Split string by new line, remove whitespace, and skip empty lines
        return param_variable.split('\n').collect{ it.trim() }.findAll{ it }
    }
    return [param_variable]
}

/**
 * Format a variable with a flag.
 *
 * If the variable is null, an empty string is returned.
 * Otherwise, the variable is formatted as "${flag} ${var}".
 *
 * @param var The variable to format.
 * @param flag The flag to prepend to the variable.
 * @return The formatted string.
 */
def format_flag(var, flag) {
    def ret = (var == null ? "" : "${flag} ${var}")
    return ret
}

/**
 * Format a variable with a flag.
 *
 * If the variable is null, an empty string is returned.
 * If the variable is a List, each element is formatted with the flag and joined by spaces.
 * Otherwise, the variable is formatted as "${flag} ${var}".
 *
 * @param vars The variable or List of variables to format.
 * @param flag The flag to prepend to each variable.
 * @return The formatted string.
 */
def format_flags(vars, flag) {
    if(vars instanceof List) {
        return (vars == null ? "" : "${flag} \'${vars.join('\' ' + flag + ' \'')}\'")
    }
    return format_flag(vars, flag)
}

/**
 * Get the total size of files in the files variable.
 *
 * If the collect() opperator is called on a Channel of Paths,
 * it will emit a List<Path> if there is more than one file,
 * but a single Path object if there is only one file in the channel.
 * This function handles both variable types.
 *
 * @param files A List<Path> or a single Path.
 * @return The total size of the files as an integer.
 */
def get_total_file_sizes(files) {
    if(files instanceof List<Path>) {
        return files*.size().sum()
    } else if(files instanceof Path) {
        return files.size()
    } else {
        error "Unknown type: ${files.getClass()}"
    }
}

/**
 * Get the number of files in the files variable.
 *
 * @param files A List<Path> or a single Path.
 * @return The number of files as an integer.
 */
def get_n_files(files) {
    if(files instanceof List<Path>) {
        return files.size()
    } else if(files instanceof Path){
        return 1
    } else {
        error "Unknown type: ${files.getClass()}"
    }
}

/**
 * Resolve a user-supplied path parameter to a Path with clear, parameter-attributed
 * error messages instead of bare NIO exceptions (e.g. an opaque `ERROR ~ /root`).
 *
 * Local paths only: remote/URL values (Panorama Public, http(s), etc.) keep Nextflow's
 * native `checkIfExists` handling, since they are fetched rather than read from disk.
 *
 * @param value The configured path value.
 * @param label The parameter name shown in error messages (e.g. 'spectral_library').
 * @param opts  Optional flags. Supported: [dir: true] to require a directory.
 * @return The resolved Path.
 */
def resolve_user_path(value, String label, Map opts = [:]) {
    def s = value?.toString()
    if (s == null || s.trim().isEmpty()) {
        // Checked before file(), which throws its own unattributed error on an empty string.
        error "Parameter `${label}` is set but empty. Set it to an actual path or remove it."
    }
    if (s.contains('://')) {
        // Remote input -- preserve Nextflow's existing behavior.
        return file(value, checkIfExists: true)
    }
    def p = file(value)
    if (p.toAbsolutePath().normalize().nameCount == 0) {
        // Resolves to a filesystem root ('/', '//', ...): almost always an empty placeholder.
        error "Parameter `${label}` resolved to the filesystem root (value: \"${value}\"). " +
              "This usually means an empty or placeholder value -- set it to an actual path or remove it."
    }
    if (!p.exists()) {
        error "Parameter `${label}` points to a path that does not exist (value: \"${value}\")."
    }
    if (opts.dir && !p.isDirectory()) {
        error "Parameter `${label}` is not a directory (value: \"${value}\")."
    }
    return p
}

/**
 * Reject a user-supplied file whose own name contains whitespace.
 *
 * Input files may have spaces in their names (see "Input file names" in SPECIFICATION.md).
 * This is for the rare input that cannot, so that the run stops before the first task with
 * a message naming the parameter instead of failing in the step that reads the file. Only
 * the file name is checked: a space in a directory on the way to the file is harmless,
 * because a task only ever sees the name the file is staged under.
 *
 * @param value The configured path value. Null is ignored.
 * @param label The parameter name shown in the error message.
 * @param reason Why this input cannot have a space in its name.
 */
def reject_whitespace_in_file_name(value, String label, String reason) {
    if (value == null) {
        return
    }
    def text = value.toString()
    def name = text.substring(Math.max(text.lastIndexOf('/'), text.lastIndexOf('\\')) + 1)
    if (name.any { Character.isWhitespace(it as char) }) {
        error "Parameter `${label}` points to a file with whitespace in its name (value: \"${text}\").\n" +
              "  ${reason}\n" +
              "  Rename the file so that its name has no spaces; spaces in the directories " +
              "leading to it are fine."
    }
}

/**
 * List the entries of a user-supplied directory parameter, attributing the common
 * failure modes (missing, not a directory, unreadable) to the parameter name.
 *
 * @param value The configured directory value.
 * @param label The parameter name shown in error messages.
 * @return An array of entries in the directory.
 */
def list_user_dir(value, String label) {
    def dir = resolve_user_path(value, label, [dir: true])
    try {
        return dir.listFiles()
    } catch (java.nio.file.AccessDeniedException e) {
        error "Parameter `${label}` could not be listed -- permission denied at ${e.message} (value: \"${value}\")."
    }
}

/**
 * Validate user-supplied batch names.
 *
 * Batch names become filename components (`<document_name>_<batch>.sky.zip`), so a name
 * containing a path separator produces an unwritable path and fails deep inside a Skyline
 * process. Reject the shapes that break rather than silently rewriting the user's names.
 * Spaces inside a name are allowed; callers trim surrounding whitespace before validating
 * (see normalize_batch_map and parse_batch_file), so it never reaches here.
 *
 * @param names The batch names to check.
 * @param label The parameter the names came from, shown in error messages.
 */
def validate_batch_names(names, String label) {
    names.each { name ->
        if (name == null || name.toString().trim().isEmpty()) {
            error "Parameter `${label}` contains an empty batch name. Every batch must have a name."
        }
        def n = name.toString()
        if (n.contains('/') || n.contains('\\')) {
            error "Parameter `${label}` contains an invalid batch name: \"${n}\".\n" +
                  "  Batch names become part of a file name (e.g. `final_${n}.sky.zip`), so they " +
                  "cannot contain '/' or '\\'."
        }
        if (n.any { Character.isISOControl(it as char) }) {
            error "Parameter `${label}` contains a batch name with control characters (value: \"${n}\").\n" +
                  "  Batch names become part of a file name and must be printable text."
        }
    }
}

/**
 * Characters that cannot appear in the name of a Skyline document.
 *
 * / and \ are path separators; : * ? " < > | cannot be in a Windows file name, so Skyline
 * cannot save the document; ' ` and $ end or expand the quoted strings the name is written
 * into in the task scripts.
 */
def document_name_forbidden_chars() {
    return '/\\:*?"<>|\'`$'
}

/**
 * @param name A document name, or a part of one such as a batch name.
 * @return The distinct forbidden characters found in the name, in order of appearance.
 */
def forbidden_document_name_chars(String name) {
    def forbidden = document_name_forbidden_chars()
    return name.toList().findAll { forbidden.contains(it) }.unique()
}

/**
 * Check batch names against the characters a Skyline document name cannot contain.
 *
 * In multi-batch mode the batch name is part of the document name
 * (`<document_name>_<batch>.sky.zip`), so a character that cannot be in a document name
 * cannot be in a batch name either. Call this only when a Skyline document will be made:
 * validate_batch_names applies to every run, and a batch name with one of these characters
 * can work when no document is written (msconvert_only, skyline.skip).
 *
 * Only the forbidden characters are checked. validate_batch_names already rejects control
 * characters, surrounding whitespace is trimmed before this point, and a leading '-' is not
 * at the start of the document name.
 *
 * @param names The batch names, already trimmed.
 * @param label The parameter the names came from, shown in error messages.
 */
def validate_batch_names_for_documents(names, String label) {
    names.each { name ->
        if (name == null) {
            return
        }
        def n = name.toString()
        def found = forbidden_document_name_chars(n)
        if (found) {
            error "Parameter `${label}` contains a batch name with characters that cannot be used in a " +
                  "Skyline document name: ${found.join(' ')} (batch name: \"${n}\").\n" +
                  "  The batch name becomes part of the document name (`<document_name>_<batch>.sky.zip`), " +
                  "which is written by Skyline, a Windows program, from shell scripts.\n" +
                  "  Spaces are allowed, but none of: ${document_name_forbidden_chars().toList().join(' ')}"
        }
    }
}

/**
 * Validate the base name of the Skyline document (params.skyline.document_name, or the PDC
 * study name that replaces the default on PDC runs).
 *
 * The name becomes the start of file names (`<name>.sky.zip`, `<name>_diann_lib.blib`,
 * `<name>_qc_report.html`), is written into the task scripts inside quotes, and is passed
 * to Skyline, a Windows program run under wine. Spaces are fine, as is most punctuation.
 * Like validate_batch_names, this rejects only the shapes that cannot produce a document,
 * so that they stop the run before the first task instead of deep inside a Skyline step,
 * and it never rewrites the name. A null or empty name is left alone.
 *
 * This is the single startup check on the document name: any further rule about what the
 * name may be (reserved names, suffixes) belongs here.
 *
 * @param name The document base name.
 * @param label The parameter the name came from, shown in error messages.
 */
def validate_document_name(name, String label) {
    if (name == null || name.toString().isEmpty()) {
        return
    }
    def n = name.toString()
    def explain = "\n  The document name becomes part of file names (e.g. `<name>.sky.zip`) that are written " +
                  "by Skyline, a Windows program, from shell scripts."

    if (n.any { Character.isISOControl(it as char) }) {
        error "Parameter `${label}` contains control characters (value: \"${n}\").${explain}"
    }
    def found = forbidden_document_name_chars(n)
    if (found) {
        error "Parameter `${label}` contains characters that cannot be used in a Skyline document name: " +
              "${found.join(' ')} (value: \"${n}\").${explain}\n" +
              "  Spaces are allowed, but none of: ${document_name_forbidden_chars().toList().join(' ')}"
    }
    if (Character.isWhitespace(n.charAt(0))) {
        // Skyline drops leading whitespace from the name of the .sky.zip it shares, so the
        // file the workflow expects is never written.
        error "Parameter `${label}` starts with whitespace (value: \"${n}\").${explain}\n" +
              "  Spaces inside the name are allowed, but it cannot start with one."
    }
    if (n.startsWith('-')) {
        // The file names are handed to command-line tools, which read a leading '-' as an option.
        error "Parameter `${label}` starts with '-' (value: \"${n}\").${explain}\n" +
              "  It cannot start with '-', which command-line tools read as an option."
    }
}

/**
 * Normalize a batch map (e.g. params.quant_spectra_dir given as a Map): trim surrounding
 * whitespace from every batch name and validate the result. Non-Map values pass through
 * untouched, so callers can hand this any accepted quant_spectra_dir shape.
 *
 * Must be applied once and the result shared by every consumer of the map. get_ms_files keys
 * its channels off these names and the Skyline document join matches on them, so trimming in
 * one place and not another would surface as a join mismatch rather than a clear error.
 *
 * @param value The configured parameter value.
 * @param label The parameter name shown in error messages.
 * @return The map with trimmed batch names, or the original value if it is not a Map.
 */
def normalize_batch_map(value, String label) {
    if (!(value instanceof Map)) {
        return value
    }
    def normalized = [:]
    value.each { k, v ->
        def name = k == null ? '' : k.toString().trim()
        if (name.isEmpty()) {
            error "Parameter `${label}` contains an empty batch name. Every batch must have a name."
        }
        if (normalized.containsKey(name)) {
            error "Parameter `${label}` contains the batch name '${name}' more than once. " +
                  "Batch names are compared after trimming surrounding whitespace, so " +
                  "'${name}' and ' ${name} ' are the same batch."
        }
        normalized[name] = v
    }
    validate_batch_names(normalized.keySet().toList(), label)
    return normalized
}

/**
 * Parse a batch file: a TSV with `file_name` and `batch` columns assigning each file to a
 * named batch. Blank lines are ignored so a trailing newline in a hand-edited file is not
 * an error. Short or partially-filled rows are reported with their line number instead of
 * failing with an IndexOutOfBoundsException.
 *
 * @param batch_file_path The configured path to the batch file.
 * @param label The parameter the path came from, shown in error messages.
 * @return A Map of file_name -> batch_name, in file order.
 */
def parse_batch_file(batch_file_path, String label = 'pdc.batch_file') {
    def f = resolve_user_path(batch_file_path, label)
    def lines = f.readLines()
    def data_lines = []
    lines.eachWithIndex { line, idx ->
        // idx is 0-based over all lines; report 1-based line numbers to the user.
        if (line != null && !line.trim().isEmpty()) {
            data_lines << [idx + 1, line]
        }
    }
    if (data_lines.size() < 2) {
        error "Parameter `${label}` points to a batch file with no data rows " +
              "(value: \"${batch_file_path}\"). It must have a header row and at least one data row."
    }

    def header = data_lines[0][1].split('\t')
    def file_name_idx = header.findIndexOf { it.trim() == 'file_name' }
    def batch_idx = header.findIndexOf { it.trim() == 'batch' }
    if (file_name_idx < 0 || batch_idx < 0) {
        error "Parameter `${label}` points to a batch file missing required columns " +
              "(value: \"${batch_file_path}\"). It must have both a 'file_name' and a 'batch' column, " +
              "found: [${header.collect{ it.trim() }.join(', ')}]."
    }
    def required_fields = Math.max(file_name_idx, batch_idx) + 1

    def batch_map = [:]
    data_lines.drop(1).each { entry ->
        def line_no = entry[0]
        def fields = entry[1].split('\t')
        if (fields.size() < required_fields) {
            error "Parameter `${label}`: line ${line_no} of \"${batch_file_path}\" has " +
                  "${fields.size()} column(s) but ${required_fields} are required.\n" +
                  "  Line: \"${entry[1]}\""
        }
        def fname = fields[file_name_idx].trim()
        def batch = fields[batch_idx].trim()
        if (fname.isEmpty()) {
            error "Parameter `${label}`: line ${line_no} of \"${batch_file_path}\" has an empty 'file_name'."
        }
        if (batch.isEmpty()) {
            error "Parameter `${label}`: line ${line_no} of \"${batch_file_path}\" has an empty 'batch' " +
                  "for file '${fname}'."
        }
        if (batch_map.containsKey(fname) && batch_map[fname] != batch) {
            error "Parameter `${label}`: file '${fname}' is assigned to more than one batch " +
                  "('${batch_map[fname]}' and '${batch}') in \"${batch_file_path}\"."
        }
        batch_map[fname] = batch
    }

    // .toList() first: values() is an unmodifiable view and Groovy's unique() mutates in place.
    validate_batch_names(batch_map.values().toList().unique(), label)
    return batch_map
}
