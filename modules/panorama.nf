// Modules/process for interacting with PanoramaWeb

def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /usr/local/bin/PanoramaClient.jar"
}

String escapeRegex(String str) {
    return str.replaceAll(/([.\^$+?{}\[\]\\|()])/) { match, group -> '\\' + group }
}

process PANORAMA_GET_RAW_FILE_LIST {
    label 'process_low_constant'
    container 'mriffle/panorama-client:1.0.0'
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy'

    input:
        each web_dav_url
        val file_glob

    output:
        tuple val(web_dav_url), path("*.download"), emit: raw_file_placeholders
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:

    // convert glob to regex that we can use to grep lines from a file of filenames
    String regex = '^' + escapeRegex(file_glob).replaceAll("\\*", ".*") + '$'

    """
    echo "Running file list from Panorama..."
        ${exec_java_command(task.memory)} \
        -l \
        -e raw \
        -w "${web_dav_url}" \
        -k \$PANORAMA_API_KEY \
        -o panorama_files.txt \
        > >(tee "panorama-get-files.stdout") 2> >(tee "panorama-get-files.stderr" >&2) && \
        grep -P '${regex}' panorama_files.txt | xargs -I % sh -c 'touch %.download'

    echo "Done!" # Needed for proper exit
    """

    stub:
    """
    touch "panorama_files.txt"
    """
}

process PANORAMA_GET_SKYLINE_TEMPLATE {
    label 'process_low_constant'
    container 'mriffle/panorama-client:1.0.0'
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stderr"

    input:
        val web_dav_dir_url

    output:
        path("${file(web_dav_dir_url).name}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(web_dav_dir_url).name
        """
        echo "Downloading ${file_name} from Panorama..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${web_dav_dir_url}" \
            -k \$PANORAMA_API_KEY \
            > >(tee "panorama-get-${file_name}.stdout") 2> >(tee "panorama-get-${file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "{$file(web_dav_dir_url).name}"
    """
}

process PANORAMA_GET_FASTA {
    label 'process_low_constant'
    container 'mriffle/panorama-client:1.0.0'
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stderr"

    input:
        val web_dav_dir_url

    output:
        path("${file(web_dav_dir_url).name}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(web_dav_dir_url).name
        """
        echo "Downloading ${file_name} from Panorama..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${web_dav_dir_url}" \
            -k \$PANORAMA_API_KEY \
            > >(tee "panorama-get-${file_name}.stdout") 2> >(tee "panorama-get-${file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "{$file(web_dav_dir_url).name}"
    """
}

process PANORAMA_GET_SPECTRAL_LIBRARY {
    label 'process_low_constant'
    container 'mriffle/panorama-client:1.0.0'
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stderr"

    input:
        val web_dav_dir_url

    output:
        path("${file(web_dav_dir_url).name}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(web_dav_dir_url).name
        """
        echo "Downloading ${file_name} from Panorama..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${web_dav_dir_url}" \
            -k \$PANORAMA_API_KEY \
            > >(tee "panorama-get-${file_name}.stdout") 2> >(tee "panorama-get-${file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "{$file(web_dav_dir_url).name}"
    """
}

process PANORAMA_GET_RAW_FILE {
    label 'process_low_constant'
    maxForks 8
    container 'quay.io/protio/panorama-client:1.0.0'
    storeDir "${params.panorama_cache_directory}"

    input:
        tuple val(web_dav_dir_url), path(download_file_placeholder)

    output:
        path("${download_file_placeholder.baseName}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        raw_file_name = download_file_placeholder.baseName
        """
        echo "Downloading ${raw_file_name} from Panorama..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${web_dav_dir_url}${raw_file_name}" \
            -k \$PANORAMA_API_KEY \
            > >(tee "panorama-get-${raw_file_name}.stdout") 2> >(tee "panorama-get-${raw_file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "{$download_file_placeholder.baseName}"
    """
}

process PANORAMA_GET_SKYR_FILE {
    label 'process_low_constant'
    container 'mriffle/panorama-client:1.0.0'
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stderr"

    input:
        val web_dav_dir_url

    output:
        path("${file(web_dav_dir_url).name}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(web_dav_dir_url).name
        """
        echo "Downloading ${file_name} from Panorama..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${web_dav_dir_url}" \
            -k \$PANORAMA_API_KEY \
            > >(tee "panorama-get-${file_name}.stdout") 2> >(tee "panorama-get-${file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "{$file(web_dav_dir_url).name}"
    """
}

process UPLOAD_FILE {
    label 'process_low_constant'
    maxForks 8
    container 'mriffle/panorama-client:1.0.0'
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stderr"

    input:
        tuple path(file_to_upload), val(web_dav_dir_url)

    output:
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(file_to_upload).name
        """
        echo "Uploading ${file_to_upload} to Panorama..."
            ${exec_java_command(task.memory)} \
            -u \
            -f "${file_to_upload}" \
            -w "${web_dav_dir_url}" \
            -k \$PANORAMA_API_KEY \
            -c \
            > >(tee "panorama-upload-${file_name}.stdout") 2> >(tee "panorama-upload-${file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """
}
