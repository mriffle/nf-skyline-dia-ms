// Modules
include { SKYLINE_RUN_REPORTS } from "../modules/skyline"

workflow skyline_reports {

    take:
        skyline_zipfile
        skyr_file_ch

    emit:
        skyline_report_files

    main:

        SKYLINE_RUN_REPORTS(
            skyline_zipfile,
            skyr_file_ch.collect()
        )

        skyline_report_files = SKYLINE_RUN_REPORTS.out.skyline_report_files
}
