
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
    if (s != null && s.contains('://')) {
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
