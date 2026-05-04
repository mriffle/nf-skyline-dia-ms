
/**
 * Shell-quote a value for safe use in generated Bash.
 */
def shell_quote(value) {
    return "'" + value.toString().replace("'", "'\"'\"'") + "'"
}

/**
 * Generate the msconvert options based off user defined parameters.
 *
 * This intentionally does not include:
 *   - wine
 *   - msconvert
 *   - input file
 *
 * Those are handled by the wrapper so we can strictly validate output.
 */
def msconvert_options() {
    def opts = '-v --zlib --mzML --64 --ignoreUnknownInstrumentError --filter "peakPicking true 1-"'
    if (params.msconvert.do_demultiplex) {
        opts += ' --filter "demultiplex optimization=overlap_only"'
    }
    if (params.msconvert.do_simasspectra) {
        opts += ' --simAsSpectra'
    }
    if (params.msconvert.mz_shift_ppm != null) {
        opts += " --filter \"mzShift ${params.msconvert.mz_shift_ppm}ppm msLevels=1-\""
    }
    return opts
}

/**
 * Generate the msconvert command text used for cache hashing.
 */
def msconvert_command() {
    return "wine msconvert ${msconvert_options()}"
}

/**
 * Generate the wrapped msconvert script.
 *
 * This wrapper handles two failure modes:
 *
 *   1. msconvert.exe terminates, but Wine/wineserver/winedevice remain alive
 *      indefinitely.
 *
 *   2. Wine exits with status 0 even though msconvert failed to produce the
 *      expected mzML file.
 */
def msconvert_wrapped_script(raw_file) {
    def expected_mzml = "${raw_file.baseName}.mzML"

    return """
    set -euo pipefail

    export WINEDEBUG=-all

    # Maximum time (seconds) to wait for msconvert.exe to first appear in the
    # process table after launching wine. If we never see it within this
    # window, wine is presumed hung and we force-cleanup.
    WINE_OBSERVE_TIMEOUT=60

    raw_file=${shell_quote(raw_file)}
    expected_mzml=${shell_quote(expected_mzml)}

    cleanup_wine() {
        rc=\$?
        trap - EXIT

        echo "Cleaning up Wine processes..." >&2
        timeout 20s wineserver -w >/dev/null 2>&1 || true
        wineserver -k >/dev/null 2>&1 || true

        exit "\$rc"
    }

    trap cleanup_wine EXIT TERM INT

    msconvert_is_running() {
        # Check the process name, not the full command line.
        #
        # The parent process may look like:
        #
        #   wine msconvert ...
        #
        # even after the actual Windows msconvert.exe process has exited.
        # Therefore we only want to detect the real msconvert/msconvert.exe
        # process, excluding zombie processes.
        #
        # Note: this scans every PID visible to the script. That is correct
        # under Docker/Singularity (each Nextflow task runs in its own PID
        # namespace, so we only see our own msconvert), which is how this
        # workflow is normally executed. If MSCONVERT is ever run without
        # PID-isolated containers, two concurrent tasks would see each
        # other's msconvert.exe and could mask each other's hangs.
        ps -eo stat=,comm=,args= \\
            | awk '\$1 !~ /^Z/ && (\$2 == "msconvert.exe" || \$2 == "msconvert") { found=1 } END { exit !found }'
    }

    # Validate that an mzML was produced AND is structurally complete. msconvert
    # writes the closing </mzML> (and, for indexed mzML, </indexedmzML>) as the
    # very last bytes of the file, so a tail-grep for either tag is a reliable
    # truncation check. This catches the case where msconvert crashed mid-write
    # but wine still returned 0.
    validate_mzml_complete() {
        local f="\$1"

        if [[ ! -s "\$f" ]]; then
            echo "ERROR: mzML file was not created or is empty: \$f" >&2
            return 1
        fi

        if ! tail -c 1024 "\$f" | grep -qE '</(indexedmzML|mzML)>'; then
            echo "ERROR: mzML file does not end with </mzML> or </indexedmzML>; likely truncated: \$f" >&2
            return 1
        fi

        return 0
    }

    # Start wineserver with persistence 0 so it exits as soon as the last
    # wine client disconnects, instead of lingering for the default 3 seconds.
    wineserver -p0 >/dev/null 2>&1 || true

    saw_msconvert=0
    forced_wine_cleanup=0
    wine_rc=0

    # Stage the conversion into a sibling directory so the expected output path
    # only ever contains a fully validated file. If msconvert crashes mid-write
    # (with or without wine reporting it), the partial output stays in
    # .pending and the task fails before promoting it.
    mkdir -p .pending

    wine msconvert ${msconvert_options()} \\
        --outdir .pending \\
        "\$raw_file" &

    wine_pid=\$!
    launched_at=\$SECONDS

    # Phase 1: poll fast until we either observe msconvert.exe, wine exits, or
    # we hit the observation timeout. The timeout catches the case where wine
    # is hung but msconvert.exe never appeared (or appeared and vanished
    # entirely between polls).
    while kill -0 "\$wine_pid" 2>/dev/null; do
        if msconvert_is_running; then
            saw_msconvert=1
            break
        fi
        if (( SECONDS - launched_at >= WINE_OBSERVE_TIMEOUT )); then
            echo "Never observed msconvert.exe within \${WINE_OBSERVE_TIMEOUT}s. Killing wineserver." >&2
            forced_wine_cleanup=1
            wineserver -k >/dev/null 2>&1 || true
            break
        fi
        sleep 1
    done

    # Phase 2: msconvert.exe was seen. Poll at a relaxed interval and trigger
    # cleanup if it disappears while wine is still alive (the original hang).
    if [[ "\$saw_msconvert" == "1" ]]; then
        while kill -0 "\$wine_pid" 2>/dev/null; do
            if ! msconvert_is_running; then
                echo "msconvert.exe was running and has now exited, but Wine is still alive. Killing wineserver." >&2
                forced_wine_cleanup=1
                wineserver -k >/dev/null 2>&1 || true
                break
            fi
            sleep 5
        done
    fi

    wait "\$wine_pid" || wine_rc=\$?

    pending_mzml=".pending/\$expected_mzml"

    if ! validate_mzml_complete "\$pending_mzml"; then
        echo "ERROR: msconvert/Wine exit code was \$wine_rc, but \$pending_mzml is missing or truncated." >&2
        echo "Files in .pending:" >&2
        ls -lh -- .pending/ 2>/dev/null >&2 || true
        exit 1
    fi

    # Promote the validated file to the expected output path. Nextflow's output
    # check now sees only a fully validated mzML.
    mv -- "\$pending_mzml" "\$expected_mzml"

    if [[ "\$forced_wine_cleanup" == "1" ]]; then
        echo "Wine was force-cleaned after msconvert.exe exited. Validated mzML: \$expected_mzml" >&2
        exit 0
    fi

    if [[ "\$wine_rc" -ne 0 ]]; then
        echo "ERROR: Wine/msconvert exited with non-zero code: \$wine_rc" >&2
        exit "\$wine_rc"
    fi

    exit 0
    """
}

/**
 * Calculate a unique hash for msconvert configuration.
 *
 * The hash combines the text of the msconvert command without the raw file and
 * the proteowizard container.
 */
def msconvert_cache_dir() {
    def str = params.images.proteowizard + msconvert_command()
    return str.md5()
}

process MSCONVERT_MULTI_BATCH {
    storeDir { "${params.mzml_cache_directory}/${msconvert_cache_dir()}" }
    publishDir params.output_directories.msconvert, pattern: "*.mzML", failOnError: true, mode: 'copy', enabled: params.msconvert_only && !params.panorama.upload
    label 'process_medium'
    label 'process_high_memory'
    label 'error_retry'
    label 'proteowizard'
    container params.images.proteowizard

    tag "${raw_file.baseName}"

    input:
        tuple val(batch), path(raw_file)

    output:
        tuple val(batch), path("${raw_file.baseName}.mzML"), emit: mzml_file

    script:
    """
    ${msconvert_wrapped_script(raw_file)}
    """

    stub:
    """
    touch '${raw_file.baseName}.mzML'
    """
}

process MSCONVERT {
    storeDir { "${params.mzml_cache_directory}/${msconvert_cache_dir()}" }
    publishDir params.output_directories.msconvert, pattern: "*.mzML", failOnError: true, mode: 'copy', enabled: params.msconvert_only && !params.panorama.upload
    label 'process_medium'
    label 'process_high_memory'
    label 'error_retry'
    label 'proteowizard'
    container params.images.proteowizard

    tag "${raw_file.baseName}"

    input:
        path(raw_file)

    output:
        path("${raw_file.baseName}.mzML"), emit: mzml_file

    script:
    """
    ${msconvert_wrapped_script(raw_file)}
    """

    stub:
    """
    touch '${raw_file.baseName}.mzML'
    """
}

process UNZIP_DIRECTORY {
    label 'process_medium'
    label 'ubuntu'
    container params.images.proteowizard
    maxForks 1

    input:
        tuple val(batch), path(zip_file)

    output:
        tuple val(batch), path("${zip_file.baseName}", type: "dir")

    script:
        """
        base="${zip_file.baseName}"
        tmpdir=\$(mktemp -d)

        unzip "${zip_file}" -d "\$tmpdir"

        found=\$(find "\$tmpdir" -type d -name "\$base" -print -quit)
        if [ -z "\$found" ]; then
           echo "ERROR: Could not locate directory '\$base' inside archive ${zip_file}" >&2
           echo "Archive listing:" >&2
           unzip -l "${zip_file}" >&2
           exit 1
        fi

        mv "\$found" "./\$base"
        """

    stub:
        """
        mkdir '${zip_file.baseName}'
        """
}