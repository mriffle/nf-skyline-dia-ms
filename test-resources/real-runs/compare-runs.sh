#!/usr/bin/env bash
#
# Compare two real runs of the same scenario, usually `main` against a change.
# See TESTING.md, "Comparing a change against main".
#
#   Usage: test-resources/real-runs/compare-runs.sh <baseline-case> <candidate-case>
#
# Compares the summaries that run-case.sh wrote: the final documents (names, ZIP contents,
# replicates, counts, audit-log entries), the list of published files, the sorted Skyline
# reports, and the spectrum counts of published mzML files.
#
# Exit status:
#   0  MATCH: everything compared is identical, and some content was compared
#   1  MISMATCH: something differs
#   2  NOT COMPARABLE: a run failed, or a summary is missing or incomplete
#   3  NO CONTENT COMPARED: the file lists are identical, but neither run produced a
#      document, a report or an mzML file, so nothing but file names was looked at
#
# Not compared, because it differs between two runs of the same code: the bytes of the
# .sky.zip (replicate order, time stamps, and the random ID of a minimized library), and
# file_checksums.tsv for the same reason.
set -uo pipefail

: "${NFDIA_TEST_HOME:?Set NFDIA_TEST_HOME to the test cache directory (see TESTING.md)}"
[ $# -eq 2 ] || { sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
a="$NFDIA_TEST_HOME/out/$1/summary"; b="$NFDIA_TEST_HOME/out/$2/summary"

echo "== $1 (baseline) vs $2 (candidate)"
for case_name in "$1" "$2"; do
    dir="$NFDIA_TEST_HOME/out/$case_name"
    info="$dir/run-info.txt"
    if [ ! -e "$info" ]; then echo "  no run-info.txt for $case_name"; echo "  => NOT COMPARABLE"; exit 2; fi
    grep '^case=\|^code=' "$info" | sed 's/^/  /'
    if ! grep -q '^case=.* exit=0 ' "$info"; then
        echo "  $case_name did not exit 0"; echo "  => NOT COMPARABLE"; exit 2
    fi
    if [ ! -e "$dir/summary/COMPLETE" ]; then
        echo "  the summary of $case_name is missing or incomplete (see $dir/summarize.log)"
        echo "  => NOT COMPARABLE"; exit 2
    fi
done
commit_a="$(sed -n 's/^code=.* commit=//p' "$a/../run-info.txt")"
commit_b="$(sed -n 's/^code=.* commit=//p' "$b/../run-info.txt")"
if [ "$commit_a" = "$commit_b" ]; then
    echo "  NOTE: both runs are of the same code ($commit_a). That shows the scenario is"
    echo "        repeatable; it does not test a change."
fi

same=1; compared=0

if [ -s "$a/documents.txt" ] || [ -s "$b/documents.txt" ]; then
    compared=$((compared + 1))
    if diff -q "$a/documents.txt" "$b/documents.txt" >/dev/null; then
        echo "  documents (names, ZIP contents, replicates, counts, audit entries): identical ($(grep -c '^DOC:' "$a/documents.txt"))"
    else
        echo "  documents: DIFFER"; diff "$a/documents.txt" "$b/documents.txt" | head -20 | sed 's/^/    /'; same=0
    fi
else
    echo "  documents: neither run made a Skyline document"
fi

if diff -q "$a/published_files.txt" "$b/published_files.txt" >/dev/null; then
    echo "  published file list: identical ($(wc -l < "$a/published_files.txt") files)"
else
    echo "  published file list: DIFFERS"
    diff "$a/published_files.txt" "$b/published_files.txt" | head -20 | sed 's/^/    /'; same=0
fi

if [ -s "$a/mzml.txt" ] || [ -s "$b/mzml.txt" ]; then
    compared=$((compared + 1))
    if diff -q "$a/mzml.txt" "$b/mzml.txt" >/dev/null; then
        echo "  published mzML files (spectrum counts): identical ($(wc -l < "$a/mzml.txt") files)"
    else
        echo "  published mzML files: DIFFER"; diff "$a/mzml.txt" "$b/mzml.txt" | head -10 | sed 's/^/    /'; same=0
    fi
fi

while read -r name; do
    compared=$((compared + 1))
    if [ ! -e "$a/reports/$name" ] || [ ! -e "$b/reports/$name" ]; then
        echo "  report $name: only in one run"; same=0
    elif cmp -s "$a/reports/$name" "$b/reports/$name"; then
        echo "  report $name: identical ($(wc -l < "$a/reports/$name") lines)"
    else
        echo "  report $name: DIFFERS in $(diff "$a/reports/$name" "$b/reports/$name" | grep -c '^<') of $(wc -l < "$a/reports/$name") lines"
        same=0
    fi
done < <(for report in "$a"/reports/*.tsv "$b"/reports/*.tsv; do
             [ -e "$report" ] && basename "$report"
         done | sort -u)

if [ "$same" = 0 ]; then echo "  => MISMATCH"; exit 1; fi
if [ "$compared" = 0 ]; then
    echo "  => NO CONTENT COMPARED (the file lists are identical; nothing else was produced)"; exit 3
fi
echo "  => MATCH"; exit 0
