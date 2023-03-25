def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /usr/local/bin/filterPIN.jar"
}

process FILTER_PIN {
    publishDir "${params.result_dir}/percolator", failOnError: true, mode: 'copy'
    label 'process_low'
    container 'quay.io/protio/encyclopedia:2.12.30'

    input:
        each path(pin)

    output:
        path("${pin.baseName}.filtered.pin"), emit: filtered_pin
        path("*.stderr"), emit: stderr

    script:
    """
    echo "Removing all non rank one hits from Percolator input file..."
        ${exec_java_command(task.memory)} ${pin} >${pin.baseName}.filtered.pin 2>${pin.baseName}.filtered.pin.stderr

    echo "Done!" # Needed for proper exit
    """

    stub:
    """
    touch "${pin.baseName}.filtered.pin"
    """
}
