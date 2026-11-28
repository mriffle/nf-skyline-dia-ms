#!/usr/bin/env bash
#
# Reduce the results of one real run to small text files that two runs can be compared by.
# run-case.sh calls this; run it by hand only to re-summarize. See TESTING.md.
#
#   Usage: test-resources/real-runs/summarize-run.sh <case>
#
# Writes $NFDIA_TEST_HOME/out/<case>/summary/:
#   documents.txt        for each final Skyline document: its name, the files in the ZIP, the
#                        replicates, the number of proteins, peptides, precursors and
#                        transitions, the number of annotations, the libraries, and the
#                        number of audit-log entries
#   published_files.txt  every published file, by path
#   mzml.txt             for each published mzML file, its number of spectra
#   reports/*.tsv        each Skyline report with its rows sorted: replicate order in the
#                        document follows import completion order, which is not repeatable
#   file_checksums.tsv, nextflow_run_details.txt   as published
#   COMPLETE             written last; compare-runs.sh refuses a summary without it
set -euo pipefail

: "${NFDIA_TEST_HOME:?Set NFDIA_TEST_HOME to the test cache directory (see TESTING.md)}"
case_name="${1:?usage: summarize-run.sh <case>}"
out="$NFDIA_TEST_HOME/out/$case_name"
results="$out/results/nf-skyline-dia-ms"
summary="$out/summary"
[ -d "$results" ] || { echo "No results in $out" >&2; exit 1; }
rm -rf "$summary"; mkdir -p "$summary/reports"

count() { grep -c "$1" "$2" || true; }     # grep -c exits 1 on a count of zero

(cd "$results" && find . -type f | LC_ALL=C sort) > "$summary/published_files.txt"

: > "$summary/documents.txt"
for zip in "$results"/skyline/final_documents/*.sky.zip; do
    [ -e "$zip" ] || continue
    unzip -Z1 "$zip" | LC_ALL=C sort > "$summary/zip-members.tmp"
    sky="$(grep '\.sky$' "$summary/zip-members.tmp" | head -1 || true)"
    skyl="$(grep '\.skyl$' "$summary/zip-members.tmp" | head -1 || true)"
    if [ -z "$sky" ]; then
        echo "No .sky file inside $zip" >&2; exit 1
    fi
    unzip -p "$zip" "$sky" > "$summary/document.sky.tmp"
    {
        echo "DOC: $(basename "$zip")"
        sed 's/^/  zip: /' "$summary/zip-members.tmp"
        if [ -n "$skyl" ]; then
            echo "  audit_log_entries: $(unzip -p "$zip" "$skyl" | grep -o '<audit_log_entry' | wc -l)"
        else
            echo "  audit_log_entries: no audit log in the document"
        fi
        echo "  replicates: $(grep -o '<replicate name="[^"]*"' "$summary/document.sky.tmp" | sed 's/<replicate name=//' | LC_ALL=C sort | tr '\n' ' ' || true)"
        echo "  proteins: $(count '<protein ' "$summary/document.sky.tmp")" \
             "peptides: $(count '<peptide ' "$summary/document.sky.tmp")" \
             "precursors: $(count '<precursor ' "$summary/document.sky.tmp")" \
             "transitions: $(count '<transition ' "$summary/document.sky.tmp")"
        echo "  annotations: $(count '<annotation name=' "$summary/document.sky.tmp")"
        echo "  libraries: $(grep -o '<[a-z_]*library [^>]*file_name_hint="[^"]*"' "$summary/document.sky.tmp" | sed 's/.*file_name_hint=//' | tr '\n' ' ' || true)"
    } >> "$summary/documents.txt"
    rm -f "$summary/document.sky.tmp" "$summary/zip-members.tmp"
done

: > "$summary/mzml.txt"
for mzml in "$results"/msconvert/*.mzML "$results"/msconvert/*/*.mzML; do
    [ -e "$mzml" ] || continue
    echo "${mzml#"$results"/}: spectra=$(count '<spectrum ' "$mzml")" >> "$summary/mzml.txt"
done

for report in "$results"/skyline/reports/*.report.tsv; do
    [ -e "$report" ] || continue
    { head -1 "$report"; tail -n +2 "$report" | LC_ALL=C sort; } > "$summary/reports/$(basename "$report")"
done
cp "$results/file_checksums.tsv" "$results/nextflow_run_details.txt" "$summary/" 2>/dev/null || true

cat "$summary/documents.txt" "$summary/mzml.txt"
echo "published files: $(wc -l < "$summary/published_files.txt")"
for report in "$summary"/reports/*.tsv; do
    [ -e "$report" ] && echo "report: $(basename "$report") ($(wc -l < "$report") lines)"
done
date -u +%Y-%m-%dT%H:%MZ > "$summary/COMPLETE"
