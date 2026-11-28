#!/usr/bin/env bash
#
# Build and verify the test cache used by real (non-stub) runs. See TESTING.md.
#
#   Usage: test-resources/real-runs/test-data.sh <command>
#
#   check        show free space, tools and what the cache already holds
#   fetch        download the FASTA and the Skyline report templates; build the reduced FASTA
#                and the replicate metadata table
#   local-raw    copy the PDC raw files the workflow downloaded into data/raw
#   derived      make the inputs that are cut from the cached mzML files: the short mzML
#                files for Cascadia, the Carafe input, and the synthetic Bruker .d.zip
#   keep-lib <case>   keep the .blib a DIA-NN case published as the library for the
#                EncyclopeDIA and no-search scenarios
#   images <core|all>  pull the container images and record their digests
#   manifest     (re)write MANIFEST.sha256 for everything under data/
#   verify       check everything under data/ against MANIFEST.sha256, and the raw files
#                the workflow downloaded against their known MD5
#
# The cache is $NFDIA_TEST_HOME. It must be outside every git repository and outside /tmp.
set -euo pipefail

: "${NFDIA_TEST_HOME:?Set NFDIA_TEST_HOME to the test cache directory (see TESTING.md)}"
HOME_DIR="$NFDIA_TEST_HOME"
DATA="$HOME_DIR/data"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FASTA_URL='https://rest.uniprot.org/uniprotkb/stream?query=(organism_id:9606)+AND+(reviewed:true)&format=fasta'
# Pinned to a commit so the files cannot change under a comparison. The workflow's own
# defaults (qc_report.*_report_template) point at the same files on `master`.
SKYR_BASE='https://raw.githubusercontent.com/ajmaurais/DIA_QC_report/8604660754c01d0b081c7798d828564ea9a5b8b4/resources'
PWIZ_IMAGE="$(sed -n "s/.*proteowizard: *'\([^']*\)'.*/\1/p" "$REPO/container_images.config")"

# The three files `pdc.n_raw_files = 3` selects from PDC000504, with the MD5 the PDC reports.
PDC_FILES=(
    'CPTAC_PDA_BioTEXT_DIA_JHU_C3L-02956_NAT_curls.raw'
    'CPTAC_PDA_BioTEXT_DIA_JHU_C3N-02754_NAT_bulk.raw'
    'CPTAC_PDA_BioTEXT_DIA_JHU_C3N-02996_Stroma_Tumor_curls.raw'
)

case "$HOME_DIR" in
    /tmp/*|/var/tmp/*) echo "NFDIA_TEST_HOME is in a temporary directory: $HOME_DIR" >&2; exit 1 ;;
    /*) ;;
    *) echo "NFDIA_TEST_HOME must be an absolute path: $HOME_DIR" >&2; exit 1 ;;
esac
if git -C "$(dirname "$HOME_DIR")" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "NFDIA_TEST_HOME is inside a git repository: $HOME_DIR" >&2; exit 1
fi

find_mzml() {  # print the cached mzML for a raw file name
    find "$HOME_DIR/nf-cache/mzml" -name "${1%.raw}.mzML" -print -quit 2>/dev/null
}

cmd_check() {
    mkdir -p "$HOME_DIR"
    echo "Test cache: $HOME_DIR"
    df -h --output=avail,pcent,target "$HOME_DIR" | sed 's/^/  /'
    if [ -d "$DATA" ]; then du -sh "$HOME_DIR"/* 2>/dev/null | sed 's/^/  /'; fi
    echo "CPUs: $(nproc)   Memory: $(free -g | awk '/^Mem:/{print $2}') GB"
    echo "Java: $("${JAVA_HOME:+$JAVA_HOME/bin/}java" -version 2>&1 | head -1)   (JAVA_HOME=${JAVA_HOME:-unset; Nextflow will use the java on PATH})"
    echo "Nextflow: $(command -v nextflow || echo 'not found')"
    if docker info >/dev/null 2>&1; then
        echo "Docker: $(docker info --format '{{.ServerVersion}}')"
        docker run --rm ubuntu:22.04 df -h --output=avail / 2>/dev/null | tail -1 | sed 's/^/  free for images: /'
    else
        echo "Docker: not available"
    fi
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        echo "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"
        if docker run --rm --gpus all ubuntu:22.04 nvidia-smi >/dev/null 2>&1; then
            echo "  Docker can use it (--gpus all works)"
        else
            echo "  Docker cannot use it (--gpus all failed)"
        fi
    else
        echo "GPU: none found"
    fi
}

cmd_fetch() {
    mkdir -p "$DATA/fasta" "$DATA/skyr"
    if [ ! -s "$DATA/fasta/human_sp_full.fasta" ]; then
        echo "Downloading human Swiss-Prot from UniProt..."
        # Download under another name first: an interrupted download must not be mistaken
        # for the file on the next run. No contact details are sent with the request.
        curl -fsS --compressed -D "$DATA/fasta/human_sp_full.headers" \
            -o "$DATA/fasta/human_sp_full.fasta.part" "$FASTA_URL"
        grep -q '^>' "$DATA/fasta/human_sp_full.fasta.part"
        mv "$DATA/fasta/human_sp_full.fasta.part" "$DATA/fasta/human_sp_full.fasta"
        grep -i '^x-uniprot-release' "$DATA/fasta/human_sp_full.headers" | tr -d '\r' \
            > "$DATA/fasta/human_sp_full.release.txt"
        rm -f "$DATA/fasta/human_sp_full.headers"
    fi
    # Every fourth entry: library prediction plus search then takes minutes, not an hour.
    awk '/^>/{n++} n%4==1' "$DATA/fasta/human_sp_full.fasta" > "$DATA/fasta/human_sp_q4.fasta"
    echo "  full FASTA: $(grep -c '^>' "$DATA/fasta/human_sp_full.fasta") entries;" \
         "reduced: $(grep -c '^>' "$DATA/fasta/human_sp_q4.fasta") entries;" \
         "$(cat "$DATA/fasta/human_sp_full.release.txt" | tr '\n' ' ')"
    for name in precursor_quality.skyr replicate_quality.skyr; do
        if [ ! -s "$DATA/skyr/$name" ]; then
            curl -fsS -o "$DATA/skyr/$name.part" "$SKYR_BASE/$name"
            mv "$DATA/skyr/$name.part" "$DATA/skyr/$name"
        fi
    done
    # Replicate metadata for the three raw files (replicate = file name without .raw).
    mkdir -p "$DATA/metadata"
    {
        printf 'Replicate\tsample_type\tprep\n'
        printf '%s\tNAT\tcurls\n' "${PDC_FILES[0]%.raw}"
        printf '%s\tNAT\tbulk\n' "${PDC_FILES[1]%.raw}"
        printf '%s\tTumor\tcurls\n' "${PDC_FILES[2]%.raw}"
    } > "$DATA/metadata/replicate_metadata.tsv"
    # Batch assignment for the PDC files (pdc.batch_file).
    {
        printf 'file_name\tbatch\n'
        printf '%s\tBatchA\n' "${PDC_FILES[0]}" "${PDC_FILES[1]}"
        printf '%s\tBatchB\n' "${PDC_FILES[2]}"
    } > "$DATA/metadata/pdc_batches.tsv"
    cmd_manifest
}

cmd_local_raw() {
    mkdir -p "$DATA/raw"
    for name in "${PDC_FILES[@]}"; do
        src="$HOME_DIR/nf-cache/panorama/$name"
        if [ ! -s "$src" ]; then
            echo "Not downloaded yet: $src" >&2
            echo "Run the pdc.config scenario once first; it downloads the files." >&2
            exit 1
        fi
        [ -s "$DATA/raw/$name" ] || cp "$src" "$DATA/raw/$name"
    done
    # The same files again as two batch directories. Hard links: no extra space.
    mkdir -p "$DATA/raw-batches/Plate1" "$DATA/raw-batches/Plate2"
    ln -f "$DATA/raw/${PDC_FILES[0]}" "$DATA/raw/${PDC_FILES[1]}" "$DATA/raw-batches/Plate1/"
    ln -f "$DATA/raw/${PDC_FILES[2]}" "$DATA/raw-batches/Plate2/"
    ls -l "$DATA/raw" | sed 's/^/  /'
    cmd_manifest
}

cmd_derived() {
    mkdir -p "$DATA/mzml-short" "$DATA/mzml" "$DATA/bruker-synthetic"
    first="$(find_mzml "${PDC_FILES[0]}")"; second="$(find_mzml "${PDC_FILES[1]}")"
    if [ -z "$first" ] || [ -z "$second" ]; then
        echo "No cached mzML files under $HOME_DIR/nf-cache/mzml." >&2
        echo "Run the pdc.config or local.config scenario once first." >&2
        exit 1
    fi
    # Carafe trains on one whole file.
    [ -s "$DATA/mzml/carafe_input.mzML" ] || cp "$second" "$DATA/mzml/carafe_input.mzML"
    # Cascadia: four minutes of gradient per file (scan time 2400 s to 2640 s).
    for src in "$first" "$second"; do
        out="$(basename "${src%.mzML}")_4min.mzML"
        [ -s "$DATA/mzml-short/$out" ] && continue
        echo "Cutting $out ..."
        docker run --rm -e WINEDEBUG=-all -e LOCAL_USER_ID="$(id -u)" -e LOCAL_GROUP_ID="$(id -g)" \
            -v "$(dirname "$src"):/in:ro" -v "$DATA/mzml-short:/out" "$PWIZ_IMAGE" \
            wine msconvert "/in/$(basename "$src")" --zlib --mzML --64 \
                --filter "scanTime [2400,2640]" --outdir /out --outfile "$out" >/dev/null
        # Wine can exit 0 without msconvert having written anything.
        if ! tail -c 200 "$DATA/mzml-short/$out" 2>/dev/null | grep -q '</indexedmzML>\|</mzML>'; then
            echo "msconvert did not write a complete $out" >&2; exit 1
        fi
    done
    # msconvert writes as root in this image; hand the files back.
    docker run --rm -v "$DATA/mzml-short:/out" ubuntu:22.04 chown -R "$(id -u):$(id -g)" /out
    # A Bruker .d.zip with no spectra in it: enough for the extraction step, nothing more.
    for name in synthetic_1 synthetic_2; do
        [ -s "$DATA/bruker-synthetic/$name.d.zip" ] && continue
        scratch="$(mktemp -d)"; mkdir "$scratch/$name.d"
        echo "synthetic Bruker directory, no spectra" > "$scratch/$name.d/analysis.tdf"
        (cd "$scratch" && zip -qr "$DATA/bruker-synthetic/$name.d.zip" "$name.d")
        rm -rf "$scratch"
    done
    du -sh "$DATA/mzml-short" "$DATA/mzml" "$DATA/bruker-synthetic" | sed 's/^/  /'
    cmd_manifest
}

cmd_keep_lib() {
    case_name="${1:?usage: test-data.sh keep-lib <case>}"
    lib="$HOME_DIR/out/$case_name/results/nf-skyline-dia-ms/diann/final_diann_lib.blib"
    [ -s "$lib" ] || lib="$(find "$HOME_DIR/out/$case_name" -name '*_diann_lib.blib' -print -quit)"
    if [ -z "$lib" ] || [ ! -s "$lib" ]; then
        echo "No *_diann_lib.blib under $HOME_DIR/out/$case_name" >&2; exit 1
    fi
    mkdir -p "$DATA/lib"
    cp "$lib" "$DATA/lib/final_diann_lib.blib"
    ls -l "$DATA/lib" | sed 's/^/  /'
    cmd_manifest
}

cmd_images() {
    set_name="${1:?usage: test-data.sh images <core|all>}"
    image_of() { sed -n "s/^ *$1: *'\([^']*\)'.*/\1/p" "$REPO/container_images.config"; }
    # core: what the two core scenarios use. all: every image the workflow can run.
    images=(ubuntu proteowizard diann pdc_client qc_pipeline)
    extra=('quay.io/mauraisa/diann:I_agree_to_the_DiaNN_2.3.0_license')
    if [ "$set_name" = all ]; then
        images+=(encyclopedia encyclopedia3_mriffle panorama_client bibliospec carafe cascadia cascadia_utils)
    fi
    mkdir -p "$HOME_DIR"
    for key in "${images[@]}"; do extra+=("$(image_of "$key")"); done
    for image in "${extra[@]}"; do
        docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image"
    done
    {
        echo "# image<TAB>digest<TAB>size, as pulled on $(date -u +%Y-%m-%d)"
        for image in "${extra[@]}"; do
            printf '%s\t%s\t%s\n' "$image" \
                "$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}local-only{{end}}' "$image" | sed 's/.*@//')" \
                "$(docker image inspect --format '{{.Size}}' "$image" | awk '{printf "%.2f GB", $1/1e9}')"
        done
    } > "$HOME_DIR/IMAGES.$set_name.tsv"
    sed 's/^/  /' "$HOME_DIR/IMAGES.$set_name.tsv"
}

cmd_manifest() {
    (cd "$DATA" && find . -type f | LC_ALL=C sort | xargs -d '\n' sha256sum) > "$HOME_DIR/MANIFEST.sha256"
    echo "  wrote $HOME_DIR/MANIFEST.sha256 ($(wc -l < "$HOME_DIR/MANIFEST.sha256") files)"
}

# MD5 of the raw files the workflow downloads into nf-cache/panorama. The PDC values are
# the ones the PDC reports; the Panorama Public ones were computed after download on
# 2026-11-27 (the sizes matched the server's listing).
KNOWN_MD5='611ec11db586f0b9a381eeab5af4aa7e  CPTAC_PDA_BioTEXT_DIA_JHU_C3L-02956_NAT_curls.raw
b6aac52f523485793264b9587f7de8c6  CPTAC_PDA_BioTEXT_DIA_JHU_C3N-02754_NAT_bulk.raw
b78dac8874eb091fd4183ecec6248545  CPTAC_PDA_BioTEXT_DIA_JHU_C3N-02996_Stroma_Tumor_curls.raw
e3ff3c0bbdd4347a9f0d902f24cdf4f2  Dora_05022024_neo_150uID_15cm_npCSF_30mGPF_A_400-500_13.raw
0534ae0c51d6dc354a0137d6090a1b0b  Dora_05022024_neo_150uID_15cm_npCSF_30mGPF_A_500-600_14.raw
04ea05c6d957288fbedb9e8b2845ca31  Dora_05022024_neo_150uID_15cm_npCSF_30mGPF_A_600-700_15.raw
f4a51f70c10f32d668fef2975f9797d7  Dora_05022024_neo_150uID_15cm_npCSF_30mGPF_A_700-800_16.raw
9780d70ced72fa8faf9541512c70a0b1  Dora_05022024_neo_150uID_15cm_npCSF_30mGPF_A_800-900_17.raw
dbe5550435214b24b1397a8e1ae1ba2b  Dora_05022024_neo_150uID_15cm_npCSF_30mGPF_A_900-1000_18.raw
c9c1d3dcab79256bc66768c5f0b5f4cb  Dora_05022024_neo_150uID_15cm_npCSF_MMCC_N01_63.raw
76b343abe17405d458b020f245e8341b  Dora_05022024_neo_150uID_15cm_npCSF_MMCC_N01_78.raw
312f69a1c5bbcf289a27f78156ef0bbf  Dora_05022024_neo_150uID_15cm_npCSF_MMCC_N01_93.raw'

cmd_verify() {
    failed=0
    # The workflow's own download cache: check whichever of the known files are there.
    present=""
    while read -r sum name; do
        if [ -e "$HOME_DIR/nf-cache/panorama/$name" ]; then present+="$sum  $name"$'\n'; fi
    done <<< "$KNOWN_MD5"
    if [ -n "$present" ]; then
        if (cd "$HOME_DIR/nf-cache/panorama" && printf '%s' "$present" | md5sum --quiet -c -); then
            echo "All $(printf '%s' "$present" | wc -l) downloaded raw files in nf-cache/panorama match their known MD5"
        else
            echo "FAILED: a downloaded raw file does not match its known MD5" >&2; failed=1
        fi
    else
        echo "No downloaded raw files in nf-cache/panorama yet"
    fi
    if [ ! -s "$HOME_DIR/MANIFEST.sha256" ]; then
        echo "FAILED: no MANIFEST.sha256 in $HOME_DIR" >&2; exit 1
    fi
    if (cd "$DATA" && sha256sum --quiet -c "$HOME_DIR/MANIFEST.sha256"); then
        echo "All $(wc -l < "$HOME_DIR/MANIFEST.sha256") files match MANIFEST.sha256"
    else
        echo "FAILED: a file under data/ does not match MANIFEST.sha256" >&2; failed=1
    fi
    unlisted="$(cd "$DATA" && find . -type f | LC_ALL=C sort | grep -vxFf <(sed 's/^[0-9a-f]*  //' "$HOME_DIR/MANIFEST.sha256") || true)"
    if [ -n "$unlisted" ]; then
        echo "FAILED: under data/ but not in the manifest:" >&2; echo "$unlisted" | sed 's/^/  /' >&2; failed=1
    fi
    return "$failed"
}

command="${1:-}"; shift || true
case "$command" in
    check) cmd_check ;;
    fetch) cmd_fetch ;;
    local-raw) cmd_local_raw ;;
    derived) cmd_derived ;;
    keep-lib) cmd_keep_lib "$@" ;;
    images) cmd_images "$@" ;;
    manifest) cmd_manifest ;;
    verify) cmd_verify ;;
    *) sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
