// Modules/process for interacting with PanoramaWeb

def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /usr/local/bin/PanoramaClient.jar"
}

String escapeRegex(String str) {
    return str.replaceAll(/([.\^$+?{}\[\]\\|()])/) { _, group -> '\\' + group }
}

String setupPanoramaAPIKeySecret(secret_id, executor_type) {

    if(executor_type != 'awsbatch') {
        return ''
    } else {
        def SECRET_NAME = 'PANORAMA_API_KEY'
        def REGION = params.aws.region

        return """
            echo "Getting Panorama API key from AWS secrets manager..."
            SECRET_JSON=\$(${params.aws.batch.cliPath} secretsmanager get-secret-value --secret-id ${secret_id} --region ${REGION} --query 'SecretString' --output text)
            PANORAMA_API_KEY=\$(echo \$SECRET_JSON | sed -n 's/.*"${SECRET_NAME}":"\\([^"]*\\)".*/\\1/p')
        """
    }
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

process PANORAMA_GET_MS_FILE_LIST {
    cache false
    label 'process_low_constant'
    label 'error_retry'
    container params.images.panorama_client
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy'
    secret 'PANORAMA_API_KEY'

    input:
        each web_dav_url
        val file_glob
        val aws_secret_id

    output:
        path('download_files.txt'), emit: ms_files
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
    // convert glob to regex that we can use to grep lines from a file of filenames
    String regex = '^' + escapeRegex(file_glob).replaceAll("\\*", ".*") + '$'

    """
    ${setupPanoramaAPIKeySecret(aws_secret_id, task.executor)}

    echo "Running file list from Panorama..."
        ${exec_java_command(task.memory)} \
        -l \
        -w "${web_dav_url}" \
        -k \$PANORAMA_API_KEY \
        -o all_files.txt \
        > >(tee "panorama-get-files.stdout") 2> >(tee "panorama-get-files.stderr" >&2) && \

    # Filter raw files by file_glob and prepend web_dav_url to file names
    grep -P '${regex}' all_files.txt | xargs -d'\\n' printf '${web_dav_url.replaceAll("%", "%%")}/%s\\n' > download_files.txt
    """
}

process PANORAMA_PUBLIC_GET_MS_FILE_LIST {
    cache false
    label 'process_low_constant'
    label 'error_retry'
    container params.images.panorama_client
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy'

    input:
        each web_dav_url
        val file_glob

    output:
        path('download_files.txt'), emit: ms_files
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
    // convert glob to regex that we can use to grep lines from a file of filenames
    String regex = '^' + escapeRegex(file_glob).replaceAll("\\*", ".*") + '$'

    """
    echo "Running file list from Panorama Public..."
        ${exec_java_command(task.memory)} \
        -l \
        -w "${web_dav_url}" \
        -k "${params.panorama.public.key}" \
        -o all_files.txt \
        > >(tee "panorama-get-files.stdout") 2> >(tee "panorama-get-files.stderr" >&2) && \

    # Filter raw files by file_glob and prepend web_dav_url to file names
    grep -P '${regex}' all_files.txt | xargs -d'\\n' printf '${web_dav_url.replaceAll("%", "%%")}/%s\\n' > download_files.txt
    """
}

process PANORAMA_GET_FILE {
    label 'process_low_constant'
    label 'error_retry'
    container params.images.panorama_client
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy', pattern: "*.stderr"
    secret 'PANORAMA_API_KEY'

    input:
        val web_dav_url
        val aws_secret_id

    output:
        path("${file(web_dav_url).name}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(web_dav_url).name
        """
        ${setupPanoramaAPIKeySecret(aws_secret_id, task.executor)}

        echo "Downloading ${file_name} from Panorama..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${web_dav_url}" \
            -k \$PANORAMA_API_KEY \
            > >(tee "panorama-get-${file_name}.stdout") 2> >(tee "panorama-get-${file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "${file(web_dav_url).name}"
    touch stub.stderr stub.stdout
    """
}

process PANORAMA_GET_MS_FILE {
    label 'process_low_constant'
    label 'error_retry'
    maxForks 4
    container params.images.panorama_client
    storeDir "${params.panorama_cache_directory}"
    secret 'PANORAMA_API_KEY'

    input:
        val web_dav_url
        val aws_secret_id

    output:
        path("${file(web_dav_url).name}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        raw_file_name = file(web_dav_url).name
        """
        ${setupPanoramaAPIKeySecret(aws_secret_id, task.executor)}

        echo "Downloading ${raw_file_name} from Panorama..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${web_dav_url}" \
            -k \$PANORAMA_API_KEY \
            > >(tee "panorama-get-${raw_file_name}.stdout") 2> >(tee "panorama-get-${raw_file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "${file(web_dav_url).name}"
    touch stub.stderr stub.stdout
    """
}

process PANORAMA_PUBLIC_GET_MS_FILE {
    label 'process_low_constant'
    label 'error_retry'
    maxForks 4
    container params.images.panorama_client
    storeDir "${params.panorama_cache_directory}"

    input:
        val web_dav_url

    output:
        path("${file(web_dav_url).name}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        raw_file_name = file(web_dav_url).name
        """
        echo "Downloading ${raw_file_name} from Panorama Public..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${web_dav_url}" \
            -k "${params.panorama.public.key}" \
            > >(tee "panorama-get-${raw_file_name}.stdout") 2> >(tee "panorama-get-${raw_file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "${file(web_dav_url).name}"
    touch stub.stderr stub.stdout
    """
}

process PANORAMA_GET_SKYR_FILE {
    label 'process_low_constant'
    label 'error_retry'
    container params.images.panorama_client
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy', pattern: "*.stderr"
    secret 'PANORAMA_API_KEY'

    input:
        val web_dav_url
        val aws_secret_id

    output:
        path("${file(web_dav_url).name}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(web_dav_url).name
        """
        ${setupPanoramaAPIKeySecret(aws_secret_id, task.executor)}

        echo "Downloading ${file_name} from Panorama..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${web_dav_url}" \
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
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy', pattern: "*.stderr"
    secret 'PANORAMA_API_KEY'

    input:
        tuple path(file_to_upload), val(web_dav_dir_url)
        val aws_secret_id

    output:
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        file_name = file(file_to_upload).name
        """
        ${setupPanoramaAPIKeySecret(aws_secret_id, task.executor)}

        echo "Uploading ${file_to_upload} to Panorama..."
            ${exec_java_command(task.memory)} \
            -u \
            -f "${file_name}" \
            -w "${web_dav_dir_url}" \
            -k \$PANORAMA_API_KEY \
            -c \
            > >(tee "panorama-upload-${file_name}.stdout") 2> >(tee "panorama-upload-${file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "panorama-upload-${file(file_to_upload).name}.stdout" \
          "panorama-upload-${file(file_to_upload).name}.stderr"
    """
}

process IMPORT_SKYLINE {
    label 'process_low_constant'
    container params.images.panorama_client
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy', pattern: "*.stdout"
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy', pattern: "*.stderr"
    secret 'PANORAMA_API_KEY'

    input:
        val uploads_finished            // not used, used as a state check to ensure this runs after all uploads are done
        val skyline_filename            // the filename of the skyline document
        val skyline_web_dav_dir_url     // the panorama webdav URL for the directory containing the skyline document
        val aws_secret_id

    output:
        path("panorama-import-skyline.stdout"), emit: stdout
        path("panorama-import-skyline.stderr"), emit: stderr

    script:
        """
        ${setupPanoramaAPIKeySecret(aws_secret_id, task.executor)}

        echo "Importing ${skyline_filename} into Panorama..."
            ${exec_java_command(task.memory)} \
            -i \
            -t "${skyline_filename}" \
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
