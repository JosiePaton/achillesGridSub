#!/bin/bash

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <runcard> <flux_file> [num_jobs] [nevents]" >&2
    exit 1
fi

RUNCARD="$(realpath "$1")"
FLUX_FILE="$(realpath "$2")"
NUM_JOBS="${3:-1}"
NEVENTS="${4:-100}"

TOP_PNFS_DIR="/pnfs/sbnd/scratch/users/jpaton/achillesSubmission/"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACHILLES_DIR="${SCRIPT_DIR}/achilles"
WORKER_SCRIPT="${SCRIPT_DIR}/run_achilles.sh"
WRAPPER_SCRIPT="${SCRIPT_DIR}/wrapper.sh"
CACHE_DIR="${ACHILLES_DIR}/.achilles"

[[ -f "${RUNCARD}" ]]                   || { echo "ERROR: Runcard not found: ${RUNCARD}" >&2; exit 1; }
grep -q "REPLACE_NEVENTS"  "${RUNCARD}" || { echo "ERROR: Runcard missing REPLACE_NEVENTS placeholder"  >&2; exit 1; }
grep -q "REPLACE_FLUXFILE" "${RUNCARD}" || { echo "ERROR: Runcard missing REPLACE_FLUXFILE placeholder" >&2; exit 1; }
[[ -f "${FLUX_FILE}" ]]                 || { echo "ERROR: Flux file not found: ${FLUX_FILE}" >&2; exit 1; }
[[ -d "${ACHILLES_DIR}/build/bin" ]]    || { echo "ERROR: achilles build not found at ${ACHILLES_DIR}" >&2; exit 1; }
[[ -f "${WORKER_SCRIPT}" ]]             || { echo "ERROR: run_achilles.sh not found" >&2; exit 1; }
[[ -f "${WRAPPER_SCRIPT}" ]]            || { echo "ERROR: wrapper.sh not found" >&2; exit 1; }

FLUX_BASENAME="$(basename "${FLUX_FILE}")"

STAGE=$(mktemp -d)
trap 'rm -rf "${STAGE}"' EXIT

echo "Staging tarball contents..."
mkdir -p "${STAGE}/achilles/build"
mkdir -p "${STAGE}/achilles/flux"
cp -r "${ACHILLES_DIR}/build/bin"  "${STAGE}/achilles/build/"
cp -r "${ACHILLES_DIR}/build/lib"  "${STAGE}/achilles/build/"
cp -r "${ACHILLES_DIR}/data"       "${STAGE}/achilles/"
cp "${FLUX_FILE}"                  "${STAGE}/achilles/flux/"
cp "${RUNCARD}"                    "${STAGE}/achilles/run_grid.yml"
cp "${WORKER_SCRIPT}"              "${STAGE}/run_achilles.sh"
chmod +x "${STAGE}/run_achilles.sh"
# FetchContent libraries (e.g. docopt, nuhepmc_cpputils) aren't installed into
# build/lib by cmake; collect them alongside the installed libs so the worker
# node can find them via LD_LIBRARY_PATH.
find "${ACHILLES_DIR}/build/_deps" -name "*.so*" -exec cp {} "${STAGE}/achilles/build/lib/" \;

# Include the pre-computed parameter cache to skip redundant on-node calculation.
# Cache is runcard-specific: run locally with the target runcard before submitting.
if [[ -d "${CACHE_DIR}" ]]; then
    echo "Including .achilles cache ($(du -sh "${CACHE_DIR}" | cut -f1))..."
    cp -r "${CACHE_DIR}" "${STAGE}/achilles/.achilles"
else
    echo "WARNING: No .achilles cache found at ${CACHE_DIR}; jobs will recompute parameters"
fi

TARBALL_LOCAL="${SCRIPT_DIR}/achilles_build.tar.gz"
echo "Building tarball (runcard: $(basename "${RUNCARD}"), flux: ${FLUX_BASENAME})..."
tar -czf "${TARBALL_LOCAL}" -C "${STAGE}" .
echo "Tarball size: $(du -sh "${TARBALL_LOCAL}" | cut -f1)"

# Each submission gets its own timestamped directory; pnfs does not allow
# overwriting existing files, so reusing a path would fail on resubmission.
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RUNCARD_STEM="$(basename "${RUNCARD}" .yml)"
UNIQUE_OUTPUT_DIR="${TOP_PNFS_DIR}${RUNCARD_STEM}_${TIMESTAMP}/"
mkdir -p "${UNIQUE_OUTPUT_DIR}" || { echo "ERROR: Could not create output dir" >&2; exit 1; }
echo "Output will go to: ${UNIQUE_OUTPUT_DIR}"

ACHILLES_TARBALL="${UNIQUE_OUTPUT_DIR}achilles_build.tar.gz"

echo "Uploading to pnfs..."
cp "${TARBALL_LOCAL}" "${ACHILLES_TARBALL}"
LOCAL_SIZE=$(stat -c%s "${TARBALL_LOCAL}")
REMOTE_SIZE=$(stat -c%s "${ACHILLES_TARBALL}" 2>/dev/null || echo 0)
[[ "${REMOTE_SIZE}" -eq "${LOCAL_SIZE}" ]] || {
    echo "ERROR: Upload failed (local=${LOCAL_SIZE} remote=${REMOTE_SIZE})" >&2; exit 1; }
echo "Upload verified (${REMOTE_SIZE} bytes)"

# wrapper.sh is submitted via file:// so condor reads it fresh each time.
# It simply execs run_achilles.sh from the unpacked tarball, which lets us
# update the worker script without waiting for RCDS cache invalidation.
jobsub_submit \
    --group=sbnd \
    --role=Analysis \
    --resource-provides=usage_model=DEDICATED,OPPORTUNISTIC \
    --memory=2000MB \
    --disk=10GB \
    --expected-lifetime=2h \
    --singularity-image /cvmfs/singularity.opensciencegrid.org/fermilab/fnal-wn-sl7:latest \
    --tar_file_name "dropbox://${ACHILLES_TARBALL}" \
    -N ${NUM_JOBS} \
    file://${WRAPPER_SCRIPT} \
        "${UNIQUE_OUTPUT_DIR}" "${NEVENTS}" "${FLUX_BASENAME}"
