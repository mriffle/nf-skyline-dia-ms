
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
 * If the collect() opperator is called on a Channel of paths,
 * it will emit a List of Paths if there is more than one file,
 * but a single Path object if there is only one file in the channel.
 * This function handles both cases.
 *
 * @param files A List of Paths or a single Path.
 * @return The number of files as an integer.
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
 * @param files A List of Paths or a single Path.
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
