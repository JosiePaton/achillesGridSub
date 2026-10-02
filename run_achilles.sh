#!/bin/bash
set -euo pipefail

SCRIPT_START=$(date +%s)

if [[ $# -ne 3 ]]; then
    echo "ERROR: Expected 3 args: OUTPUT_DIR NEVENTS FLUX_BASENAME" >&2; exit 1
fi
OUTPUT_DIR="$1"
NEVENTS="$2"
FLUX_BASENAME="$3"

if ! [[ "${NEVENTS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: NEVENTS must be a positive integer, got: ${NEVENTS}" >&2; exit 1
fi

if [[ -z "${CLUSTER:-}" || -z "${PROCESS:-}" ]]; then
    echo "ERROR: CLUSTER/PROCESS not set" >&2; exit 1
fi
echo "Job: CLUSTER=${CLUSTER} PROCESS=${PROCESS}  NEvents=${NEVENTS}  Flux=${FLUX_BASENAME}"

WORKDIR=$(mktemp -d)
trap 'echo "Cleaning up ${WORKDIR}"; rm -rf "${WORKDIR}"' EXIT
cd "${WORKDIR}"

for cvmfs_path in \
    /cvmfs/sbnd.opensciencegrid.org/products/sbnd \
    /cvmfs/larsoft.opensciencegrid.org/products; do
    [[ -d "${cvmfs_path}" ]] || { echo "ERROR: CVMFS not mounted: ${cvmfs_path}" >&2; exit 1; }
done

AVAIL_GB=$(( $(df -k "${WORKDIR}" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
[[ ${AVAIL_GB} -ge 15 ]] || { echo "ERROR: Only ${AVAIL_GB} GB available (need 15)" >&2; exit 1; }

# UPS setup scripts are not strict-mode clean; disable for the entire block.
set +eu
source /cvmfs/sbnd.opensciencegrid.org/products/sbnd/setup_sbnd.sh

# Wrapper around UPS setup that verifies success via the product's sentinel *_DIR variable.
ups_setup() {
    local product="$1"; shift
    setup "${product}" "$@"
    local sentinel_var="${product^^}_DIR"; sentinel_var="${sentinel_var//-/_}"
    [[ -n "${!sentinel_var:-}" ]] || { echo "ERROR: setup ${product} failed" >&2; return 1; }
}

ups_setup root     v6_28_12  -q e26:p3915:prof || { echo "ERROR: root setup failed"    >&2; exit 1; }
ups_setup lhapdf   v6_5_4    -q e26:p3915:prof || { echo "ERROR: lhapdf setup failed"  >&2; exit 1; }
ups_setup hepmc3   v3_3_1    -q e26:p3915:prof || { echo "ERROR: hepmc3 setup failed"  >&2; exit 1; }
ups_setup hdf5     v1_12_2b  -q e26:prof        || { echo "ERROR: hdf5 setup failed"    >&2; exit 1; }
ups_setup spdlog   v1_9_2    -q e26:prof        || { echo "ERROR: spdlog setup failed"  >&2; exit 1; }
ups_setup boost    v1_82_0   -q e26:prof        || { echo "ERROR: boost setup failed"   >&2; exit 1; }
ups_setup log4cpp  v1_1_3e   -q e26:prof        || { echo "ERROR: log4cpp setup failed" >&2; exit 1; }
setup pdfsets v5_9_1b
setup ifdhc
set -eu

# GCC 12 runtime libs required by the HEP packages above.
export LD_LIBRARY_PATH=/cvmfs/larsoft.opensciencegrid.org/products/gcc/v12_1_0/Linux64bit+3.10-2.17/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}

[[ -n "${INPUT_TAR_DIR_LOCAL:-}" ]] || { echo "ERROR: INPUT_TAR_DIR_LOCAL not set" >&2; exit 1; }
cp -r "${INPUT_TAR_DIR_LOCAL}"/* "${WORKDIR}"/

# FetchContent libraries (docopt, nuhepmc_cpputils, etc.) are collected into
# build/lib by the submission script so they're available alongside the binary.
export LD_LIBRARY_PATH="${WORKDIR}/achilles/build/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

ACHILLES_BIN=$(find "${WORKDIR}" -name "achilles" -type f -executable | head -1 || true)
[[ -n "${ACHILLES_BIN}" ]] || { echo "ERROR: achilles binary not found" >&2; exit 1; }

if ldd "${ACHILLES_BIN}" 2>&1 | grep -q "not found"; then
    echo "ERROR: Missing shared libraries:" >&2
    ldd "${ACHILLES_BIN}" | grep "not found" >&2
    exit 1
fi
echo "Binary: ${ACHILLES_BIN}"

RUNCARD="${WORKDIR}/achilles/run_grid.yml"
[[ -f "${RUNCARD}" ]] || { echo "ERROR: Runcard not found at ${RUNCARD}" >&2; exit 1; }
grep -q "REPLACE_NEVENTS"  "${RUNCARD}" || { echo "ERROR: Missing REPLACE_NEVENTS placeholder"  >&2; exit 1; }
grep -q "REPLACE_FLUXFILE" "${RUNCARD}" || { echo "ERROR: Missing REPLACE_FLUXFILE placeholder" >&2; exit 1; }
[[ -f "${WORKDIR}/achilles/flux/${FLUX_BASENAME}" ]] || {
    echo "ERROR: Flux file not found in tarball: flux/${FLUX_BASENAME}" >&2; exit 1; }
sed -i "s/REPLACE_NEVENTS/${NEVENTS}/"     "${RUNCARD}"
sed -i "s/REPLACE_FLUXFILE/${FLUX_BASENAME}/" "${RUNCARD}"

cd "${WORKDIR}/achilles"
echo "Running ACHILLES (${NEVENTS} events)..."
RUN_START=$(date +%s)
"${ACHILLES_BIN}" run_grid.yml
echo "ACHILLES runtime: $(( $(date +%s) - RUN_START ))s"

OUTPUT_FILE=$(find "${WORKDIR}/achilles" -maxdepth 2 \( -name "*.hepmc3" -o -name "*.hepmc" \) | head -1 || true)
[[ -n "${OUTPUT_FILE}" ]] || { echo "ERROR: No output file found" >&2; exit 1; }
[[ -s "${OUTPUT_FILE}" ]] || { echo "ERROR: Output file is empty" >&2; exit 1; }

OUT_FILENAME="achilles_${CLUSTER}_${PROCESS}.hepmc3"
ifdh cp "${OUTPUT_FILE}" "${OUTPUT_DIR}/${OUT_FILENAME}"
if [[ "${PROCESS}" == "0" ]]; then
    ifdh cp "${RUNCARD}" "${OUTPUT_DIR}/run_grid.yml"
fi
echo "Output written to: ${OUTPUT_DIR}/${OUT_FILENAME}"
echo "Total wall time: $(( $(date +%s) - SCRIPT_START ))s"
