// Modules
include { SKYLINE_RUN_REPORTS } from "../modules/skyline"

workflow skyline_reports {

    take:
        skyline_zipfile
        skyr_file_ch

    main:

        SKYLINE_RUN_REPORTS(
            skyline_zipfile,
            skyr_file_ch.collect()
        )

    emit:
        skyline_report_files = SKYLINE_RUN_REPORTS.out.skyline_report_files
}
