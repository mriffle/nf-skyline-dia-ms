
include { get_ms_files } from "./get_ms_files"

workflow get_batched_ms_files {
    take:
        spectra_dirs
        spectra_glob
        aws_secret_id

    main:
        if(spectra_dirs instanceof Map) {
            use_batch_mode = true
            println(spectra_dirs)

            // Convert the Map into a channel of tuples (batch_name, dirs)
            batched_inputs = Channel.from(spectra_dirs)
                .map { batch_name, dirs ->
                    def dirs_ch = Channel.of(dirs)
                    return tuple(batch_name, dirs_ch)
                }

            batched_outputs = batched_inputs.map { batch_name, dirs_ch ->
                get_ms_files(
                    dirs_ch,
                    spectra_glob,
                    batch_name,
                    aws_secret_id
                )
                return get_ms_files.out.ms_files
            }

            // Combine all outputs into a single channel
            ms_files = Channel.concat(batched_outputs)
        } else {
            use_batch_mode = false
            get_ms_files(
                spectra_dirs,
                spectra_glob,
                null,
                aws_secret_id
            )
            ms_files = get_ms_files.out.ms_file_ch
        }

    emit:
        ms_files
        use_batch_mode
}
