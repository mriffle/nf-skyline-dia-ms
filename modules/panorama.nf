// Modules/process for interacting with PanoramaWeb

def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /usr/local/bin/PanoramaClient.jar"
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

/**
 * The name the Panorama client gives a file it downloads from a WebDAV URL.
 *
 * The client names the file after the last segment of the decoded URL path, so a URL that
 * ends in `my%20library.blib` is saved as `my library.blib`. The download processes declare
 * this name as their output; taken straight from the URL (`my%20library.blib`) it is a file
 * that is never written, and the task ends in "Missing output file(s)".
 *
 * A name without percent-escapes is returned as it is, as is one whose escapes are not valid.
 *
 * @param web_dav_url The WebDAV URL of a file.
 * @return The file name on disk after the download.
 */
def panorama_file_name(web_dav_url) {
    def url = web_dav_url.toString().trim()
    def name = url.substring(url.lastIndexOf('/') + 1)
    if (!name.contains('%')) {
        return name
    }
    try {
        // URLDecoder is for form data and would also turn '+' into a space.
        return java.net.URLDecoder.decode(name.replace('+', '%2B'), 'UTF-8')
    } catch (IllegalArgumentException e) {
        return name
    }
}

/**
 * The URL to hand to the Panorama client for a download.
 *
 * File names read from a Panorama directory listing are not URL-encoded, so a file called
 * `my file.raw` gives a URL with a space in it. The client then re-encodes the whole URL,
 * including the escapes already in it (`Panorama%20Public` becomes `Panorama%2520Public`),
 * and the server answers 404. Encoding the spaces here keeps the URL valid, so the client
 * sends it unchanged.
 *
 * @param web_dav_url The WebDAV URL of a file.
 * @return The URL with every space written as %20.
 */
def panorama_request_url(web_dav_url) {
    return web_dav_url.toString().trim().replace(' ', '%20')
}

process PANORAMA_GET_MS_FILE_LIST {
    cache false
    label 'process_low_constant'
    label 'error_retry'
    container params.images.panorama_client
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy'
    secret 'PANORAMA_API_KEY'

    input:
        tuple val(batch_name), val(web_dav_url)
        val file_regex
        val aws_secret_id

    output:
        tuple val(batch_name), path('download_files.txt'), emit: ms_files
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
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
    grep -P '${file_regex}' all_files.txt | xargs -d'\\n' printf '${web_dav_url.replaceAll("%", "%%")}/%s\\n' > download_files.txt
    """
}

process PANORAMA_PUBLIC_GET_MS_FILE_LIST {
    cache false
    label 'process_low_constant'
    label 'error_retry'
    container params.images.panorama_client
    publishDir params.output_directories.panorama, failOnError: true, mode: 'copy'

    input:
        tuple val(batch_name), val(web_dav_url)
        val file_regex

    output:
        tuple val(batch_name), path('download_files.txt'), emit: ms_files
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
    """
    echo "Running file list from Panorama Public..."
        ${exec_java_command(task.memory)} \
        -l \
        -w "${web_dav_url}" \
        -k "${params.panorama.public.key}" \
        -o all_files.txt \
        > >(tee "panorama-get-files.stdout") 2> >(tee "panorama-get-files.stderr" >&2) && \

    # Filter raw files by file_glob and prepend web_dav_url to file names
    grep -P '${file_regex}' all_files.txt | xargs -d'\\n' printf '${web_dav_url.replaceAll("%", "%%")}/%s\\n' > download_files.txt
    """

    // No server is asked in a stub run, so the listing is empty: the folder looks as if no
    // file in it matched. test-panorama-no-spectra-match.config relies on that to reach the
    // "No spectra files matched" check in get_ms_files, which only a listing can trigger.
    stub:
    """
    touch download_files.txt
    touch stub.stdout stub.stderr
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
        val(web_dav_url)
        val aws_secret_id

    output:
        // The client saves the file under the decoded name (my%20library.blib -> my library.blib).
        // Only this declaration knows that: the script block is deliberately unchanged, so that
        // a resumed run does not download the file again into a new work directory, which
        // would in turn repeat every step that reads it.
        path("${panorama_file_name(web_dav_url)}"), emit: panorama_file
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
    touch "${panorama_file_name(web_dav_url)}"
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
        tuple val(batch_name), val(web_dav_url)
        val aws_secret_id

    output:
        tuple val(batch_name), path("${panorama_file_name(web_dav_url)}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        raw_file_name = panorama_file_name(web_dav_url)
        """
        ${setupPanoramaAPIKeySecret(aws_secret_id, task.executor)}

        echo "Downloading ${raw_file_name} from Panorama..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${panorama_request_url(web_dav_url)}" \
            -k \$PANORAMA_API_KEY \
            > >(tee "panorama-get-${raw_file_name}.stdout") 2> >(tee "panorama-get-${raw_file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "${panorama_file_name(web_dav_url)}"
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
        tuple val(batch_name), val(web_dav_url)

    output:
        tuple val(batch_name), path("${panorama_file_name(web_dav_url)}"), emit: panorama_file
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
        raw_file_name = panorama_file_name(web_dav_url)
        """
        echo "Downloading ${raw_file_name} from Panorama Public..."
            ${exec_java_command(task.memory)} \
            -d \
            -w "${panorama_request_url(web_dav_url)}" \
            -k "${params.panorama.public.key}" \
            > >(tee "panorama-get-${raw_file_name}.stdout") 2> >(tee "panorama-get-${raw_file_name}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "${panorama_file_name(web_dav_url)}"
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
        path("${panorama_file_name(web_dav_url)}"), emit: panorama_file
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

        echo "Uploading ${file_name} to Panorama..."
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
    # Record the destination so stub runs can verify upload routing, which is otherwise
    # invisible: the real command is skipped and the URL appears nowhere else.
    echo "would upload ${file(file_to_upload).name} to ${web_dav_dir_url}" \
        > "panorama-upload-${file(file_to_upload).name}.stdout"
    touch "panorama-upload-${file(file_to_upload).name}.stderr"
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
        // Named after the document being imported: in batch mode this process runs once per
        // document and every task publishes into the same directory, so a fixed name would
        // mean only one batch's log survives. Matches UPLOAD_FILE's naming.
        path("panorama-import-${skyline_filename}.stdout"), emit: stdout
        path("panorama-import-${skyline_filename}.stderr"), emit: stderr

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
            > >(tee "panorama-import-${skyline_filename}.stdout") 2> >(tee "panorama-import-${skyline_filename}.stderr" >&2)
        echo "Done!" # Needed for proper exit
        """

    stub:
    """
    touch "panorama-import-${skyline_filename}.stdout" "panorama-import-${skyline_filename}.stderr"
    """
}
