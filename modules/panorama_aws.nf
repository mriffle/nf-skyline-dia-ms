// Modules/process for interacting with PanoramaWeb

def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /usr/local/bin/PanoramaClient.jar"
}

String escapeRegex(String str) {
    return str.replaceAll(/([.\^$+?{}\[\]\\|()])/) { match, group -> '\\' + group }
}

/**
 * Get the Panorama project webdav URL for the given Panorama webdav directory
 *
 * @param webdavDirectory The full URL to the WebDav directory on the Panorama server.
 * @return The modified URL pointing to the project's main view page.
 * @throws IllegalArgumentException if the input URL does not contain the required segments.
 */
String getPanoramaProjectURLForWebDavDirectory(String webdavDirectory) {
    def uri = new URI(webdavDirectory)

    def pathSegments = uri.path.split('/')
    pathSegments = pathSegments.findAll { it && it != '_webdav' }

    int cutIndex = pathSegments.indexOf('@files')
    if (cutIndex != -1) {
        pathSegments = pathSegments.take(cutIndex)
    }

    def basePath = pathSegments.collect { URLEncoder.encode(it, "UTF-8") }.join('/')
    def encodedProjectView = URLEncoder.encode('project-begin.view', 'UTF-8')
    def newUrl = "${uri.scheme}://${uri.host}/${basePath}/${encodedProjectView}"

    return newUrl
}

String setupPanoramaAPIKeySecret() {

    SECRET_ID   = 'NF_SKYLINE_DIA_MS_SECRETS'
    SECRET_NAME = 'PANORAMA_API_KEY'
    REGION = 'us-west-2'
    
    return """
        SECRET_JSON=\$(/usr/local/aws-cli/v2/current/bin/aws secretsmanager get-secret-value --secret-id ${SECRET_ID} --region ${REGION} --query 'SecretString' --output text)
        PANORAMA_API_KEY=\$(echo \$SECRET_JSON | sed -n 's/.*"${SECRET_NAME}":"\\([^"]*\\)".*/\\1/p')
    """
}

process PANORAMA_GET_RAW_FILE_LIST_AWS {
    cache false
    label 'process_low_constant'
    label 'error_retry'
    container params.images.panorama_client
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy'

    input:
        each web_dav_url
        val file_glob
        path secret_setup_done

    output:
        tuple val(web_dav_url), path("*.download"), emit: raw_file_placeholders
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
    // convert glob to regex that we can use to grep lines from a file of filenames
    String regex = '^' + escapeRegex(file_glob).replaceAll("\\*", ".*") + '$'

    """
    ${setupPanoramaAPIKeySecret()}

    echo "Value of PANORAMA_API_KEY: \$PANORAMA_API_KEY"

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
}

process PANORAMA_GET_FILE {
    label 'process_low_constant'
    label 'error_retry'
    container params.images.panorama_client
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stderr"

    input:
        val web_dav_dir_url
        path secret_setup_done


    output:
        path("${file(web_dav_dir_url).name}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(web_dav_dir_url).name
        """
        ${setupPanoramaAPIKeySecret()}

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
    touch "${file(web_dav_dir_url).name}"
    touch stub.stderr stub.stdout
    """
}

process PANORAMA_GET_RAW_FILE {
    label 'process_low_constant'
    label 'error_retry'
    maxForks 4
    container params.images.panorama_client
    storeDir "${params.panorama_cache_directory}"

    input:
        tuple val(web_dav_dir_url), path(download_file_placeholder)
        path secret_setup_done

    output:
        path("${download_file_placeholder.baseName}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        raw_file_name = download_file_placeholder.baseName
        """
        ${setupPanoramaAPIKeySecret()}

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
    touch "${download_file_placeholder.baseName}"
    touch stub.stderr stub.stdout
    """
}

process PANORAMA_GET_SKYR_FILE {
    label 'process_low_constant'
    label 'error_retry'
    container params.images.panorama_client
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stderr"

    input:
        val web_dav_dir_url
        path secret_setup_done

    output:
        path("${file(web_dav_dir_url).name}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(web_dav_dir_url).name
        """
        ${setupPanoramaAPIKeySecret()}

        echo "Downloading ${file_name} from Panorama..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${web_dav_dir_url}" \
            -k \$PANORAMA_API_KEY \
            > >(tee "panorama-get-${file_name}.stdout") 2> >(tee "panorama-get-${file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """
}

process UPLOAD_FILE {
    label 'process_low_constant'
    label 'error_retry'
    maxForks 2
    container params.images.panorama_client
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stderr"

    input:
        tuple path(file_to_upload), val(web_dav_dir_url)
        path secret_setup_done

    output:
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(file_to_upload).name
        """
        ${setupPanoramaAPIKeySecret()}

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

    stub:
    '''
    touch stub.stderr stub.stdout
    '''
}

process IMPORT_SKYLINE {
    label 'process_low_constant'
    container params.images.panorama_client
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir "${params.result_dir}/panorama", failOnError: true, mode: 'copy', pattern: "*.stderr"

    input:
        val uploads_finished            // not used, used as a state check to ensure this runs after all uploads are done
        val skyline_filename            // the filename of the skyline document
        val skyline_web_dav_dir_url     // the panorama webdav URL for the directory containing the skyline document
        path secret_setup_done

    output:
        path("panorama-import-skyline.stdout"), emit: stdout
        path("panorama-import-skyline.stderr"), emit: stderr

    script:
        """
        ${setupPanoramaAPIKeySecret()}

        echo "Importing ${skyline_filename} into Panorama..."
            ${exec_java_command(task.memory)} \
            -i \
            -t "${skyline_filename}.sky.zip" \
            -w "${skyline_web_dav_dir_url}" \
            -p "${getPanoramaProjectURLForWebDavDirectory(skyline_web_dav_dir_url)}" \
            -k \$PANORAMA_API_KEY \
            > >(tee "panorama-import-skyline.stdout") 2> >(tee "panorama-import-skyline.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    '''
    touch panorama-import-skyline.stdout panorama-import-skyline.stderr
    '''
}
