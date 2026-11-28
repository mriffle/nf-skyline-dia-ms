#!/usr/bin/env bash
#
# Run one real (non-stub) case and keep what is needed to judge it. See TESTING.md.
#
#   Usage: test-resources/real-runs/run-case.sh <lane> <case> <code-dir> <scenario>... [-- nextflow args]
#
#   <lane>      a launch directory, $NFDIA_TEST_HOME/runs/<lane>. Every case run in the same
#               lane resumes from the ones before it, so only the steps that differ run.
#               Use one lane per code tree being compared and never run two cases in one
#               lane at the same time.
#   <case>      a name for this run; its outputs go to $NFDIA_TEST_HOME/out/<case>/
#   <code-dir>  the workflow to run: this repository, or a worktree of another commit
#   <scenario>  files in test-resources/real-runs/scenarios/ (name with or without .config),
#               or paths to other config files. machine.config is always passed first.
#
#   Example: run-case.sh a local-181 . local
#            run-case.sh a local-230-min . local diann-2.3.0 metadata minimize
#
# Lane and case names may contain only letters, digits, '.', '_' and '-'.
# The run uses an isolated secrets file holding Panorama's public key, so your real
# Nextflow secrets are never read. Set NFDIA_SECRETS_FILE to use another file.
# Set NFDIA_NO_RESUME=1 to run without -resume (everything executes, whatever the lane holds).
# Set NXF_VER to choose the Nextflow version.
#
# Exit status: that of Nextflow, or 1 if the run succeeded but could not be summarized.
set -uo pipefail

usage() { sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
: "${NFDIA_TEST_HOME:?Set NFDIA_TEST_HOME to the test cache directory (see TESTING.md)}"
[ $# -ge 4 ] || usage
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$NFDIA_TEST_HOME" in
    /tmp/*|/var/tmp/*) echo "NFDIA_TEST_HOME is in a temporary directory: $NFDIA_TEST_HOME" >&2; exit 2 ;;
    /*) ;;
    *) echo "NFDIA_TEST_HOME must be an absolute path: $NFDIA_TEST_HOME" >&2; exit 2 ;;
esac
# The names become directories that this script creates and deletes, so they are checked.
for name in "$1" "$2"; do
    if ! [[ "$name" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]]; then
        echo "Not a usable lane or case name: '$name'" >&2; exit 2
    fi
done
lane="$1"; case_name="$2"
code="$(cd "$3" 2>/dev/null && pwd)" || { echo "No such code directory: $3" >&2; exit 2; }
[ -f "$code/main.nf" ] || { echo "No main.nf in $code" >&2; exit 2; }
shift 3

configs=(-c "$HERE/machine.config"); extra=()
while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; extra=("$@"); break; fi
    if [ -f "$HERE/scenarios/${1%.config}.config" ]; then
        configs+=(-c "$HERE/scenarios/${1%.config}.config")
    elif [ -f "$1" ]; then
        configs+=(-c "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")")
    else
        echo "No such scenario or config file: $1" >&2; exit 2
    fi
    shift
done

launch="$NFDIA_TEST_HOME/runs/$lane"
out="$NFDIA_TEST_HOME/out/$case_name"
mkdir -p "$launch" && cd "$launch" || exit 2
if [ -e .running ]; then
    read -r other_pid other_case < .running
    if kill -0 "$other_pid" 2>/dev/null; then
        echo "Lane $lane is in use by case $other_case (pid $other_pid)" >&2; exit 2
    fi
fi
echo "$$ $case_name" > .running; trap 'rm -f "$launch/.running"' EXIT
rm -rf results reports

secrets="${NFDIA_SECRETS_FILE:-$NFDIA_TEST_HOME/secrets.json}"
if [ ! -e "$secrets" ]; then
    # Panorama's published public key: enough for every download from Panorama Public.
    key="$(sed -n "s/.*panorama.public.key *= *'\([^']*\)'.*/\1/p" "$code/nextflow.config")"
    printf '[{"name": "PANORAMA_API_KEY", "value": "%s"}]\n' "$key" > "$secrets"
    chmod 600 "$secrets"
fi

resume=(-resume); [ -n "${NFDIA_NO_RESUME:-}" ] && resume=()
export NXF_SECRETS_FILE="$secrets" NXF_ANSI_LOG=false
nextflow_version="$(nextflow -version 2>/dev/null | sed -n 's/.*version \([0-9.]*\).*/\1/p' | head -1)"
started=$(date +%s)
nextflow run "$code" "${configs[@]}" "${resume[@]}" "${extra[@]}" > nextflow.out 2>&1
status=$?
seconds=$(( $(date +%s) - started ))

rm -rf "$out"; mkdir -p "$out"
cp nextflow.out "$out/"; cp .nextflow.log "$out/nextflow.log" 2>/dev/null
[ -d results ] && mv results "$out/results"
[ -d reports ] && { cp reports/nf-skyline-dia-ms/execution_trace_*.txt "$out/trace.txt" 2>/dev/null; rm -rf reports; }

# One line per task, from the execution trace: status, work directory, name. The console
# output is not used for this because its format differs between Nextflow versions.
# A step skipped because its output is in a storeDir cache does not appear at all.
if [ -e "$out/trace.txt" ]; then
    awk -F'\t' 'NR > 1 { print $5 "\t" $2 "\t" $4 }' "$out/trace.txt" | LC_ALL=C sort > "$out/tasks.txt"
else
    : > "$out/tasks.txt"
fi
{
    echo "case=$case_name lane=$lane exit=$status seconds=$seconds"
    echo "code=$code commit=$(git -C "$code" rev-parse --short HEAD 2>/dev/null)$(git -C "$code" diff --quiet 2>/dev/null || echo '+uncommitted')"
    echo "configs=${configs[*]} ${resume[*]} ${extra[*]}"
    echo "date=$(date -u +%Y-%m-%dT%H:%MZ) nextflow=$nextflow_version"
    echo "tasks: $(grep -c '^COMPLETED' "$out/tasks.txt") ran, $(grep -c '^CACHED' "$out/tasks.txt") cached, $(grep -vc '^COMPLETED\|^CACHED' "$out/tasks.txt") failed or aborted"
    echo "lane work directory: $(du -sh work 2>/dev/null | cut -f1)"
} > "$out/run-info.txt"

# Keep the script and logs of every task that did not complete: the work directory will not
# last. The trace names them; the console output is searched as well in case the run died
# before the trace was written.
{
    grep -v '^COMPLETED\|^CACHED' "$out/tasks.txt" | cut -f2
    grep -o "work/[0-9a-f][0-9a-f]/[0-9a-f]\{6,\}" nextflow.out | sed 's|^work/||'
} | sort -u | while read -r prefix; do
    task_dir="$(ls -d "work/$prefix"* 2>/dev/null | head -1)"; [ -n "$task_dir" ] || continue
    mkdir -p "$out/failed-task/$(basename "$task_dir")"
    cp "$task_dir"/.command.{sh,err,out,log} "$out/failed-task/$(basename "$task_dir")/" 2>/dev/null
done

cat "$out/run-info.txt"
grep -i 'error\|exception' nextflow.out | head -n 15
if [ -d "$out/results" ]; then
    if "$HERE/summarize-run.sh" "$case_name" > "$out/summarize.log" 2>&1; then
        echo "summary: $out/summary/"
    else
        echo "SUMMARY FAILED: see $out/summarize.log" >&2
        [ "$status" -eq 0 ] && status=1
    fi
fi
exit "$status"
