
include { CALCULATE_MD5 } from "../modules/file_stats"
include { WRITE_FILE_STATS } from "../modules/file_stats"

def get_search_file_dir() {
    if(params.search_engine.toLowerCase() == 'encyclopedia') {
        return params.output_directories.encyclopedia.search_file
    }
    if(params.search_engine.toLowerCase() == 'diann') {
        return params.output_directories.diann
    }
    return 'UNKNOWN_SEARCH_ENGINE'
}


workflow combine_file_hashes {
    take:
        fasta_files
        spectral_library

        search_file_stats

        final_skyline_file
        final_skyline_hash
        skyline_reports

        qc_report_files
        gene_reports

        workflow_versions

    main:

        // process hash text files produced by search
        search_file_data = search_file_stats.splitText().map{
            it -> tuple(it.split('\\t'))
        }.branch{
            mzml_files: it[0].endsWith("mzML")
                tuple(it[0], "${params.mzml_cache_directory}", it[1], it[2])
            search_files: true
                tuple(it[0], get_search_file_dir(), it[1], it[2])
        }

        // process skyline hash text files
        skyline_doc_data = final_skyline_file.map{
            it -> tuple(it.name, params.output_directories.skyline.import_spectra, it.size())
        }.join(
            final_skyline_hash.splitText().map{ it ->
                def elems = it.trim().split('\t')
                tuple(elems[1], elems[0])
            }
        ).map{ it -> tuple(it[0], it[1], it[3], it[2])}

        // Combine files we need to calculate the hash of into a single channel
        file_stat_files = fasta_files.concat(spectral_library).map{
            it -> tuple(it.name, it, params.result_dir, it.size())
        }.concat(
            skyline_reports.map{ tuple(it.name, it, params.output_directories.skyline.reports, it.size()) },
            qc_report_files.map{ tuple(it.name, it, params.output_directories.qc_report, it.size()) },
            gene_reports.map{ tuple(it.name, it, params.output_directories.gene_reports, it.size()) },
            workflow_versions.map{ tuple(it.name, it, params.result_dir, it.size()) }
        )

        md5_input = file_stat_files.map{ it -> it[1] }
        CALCULATE_MD5(md5_input)

        // Combine all file hashes into a single channel
        output_file_hashes = search_file_data.mzml_files.concat(
            file_stat_files.join(CALCULATE_MD5.out).map{
                it -> tuple(it[0], it[2], it[4], it[3])
            }
        ).concat(search_file_data.search_files, skyline_doc_data).map{
            it -> it.join('\\t')
        }

        // output_file_hashes.view()

        WRITE_FILE_STATS(output_file_hashes.collect())

    emit:
        output_file_hashes
}

