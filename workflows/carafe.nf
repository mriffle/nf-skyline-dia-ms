
include { run_carafe } from "../subworkflows/run_carafe"

workflow carafe {
    main:
        spectral_library = Channel.empty()

    emit:
        spectral_library
}
