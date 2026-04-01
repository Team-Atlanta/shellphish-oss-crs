#!/bin/bash
# OSS-CRS glue for Shellphish Jazzer.
#
# Downloads build output, sets up wrapper.py environment,
# launches Jazzer fuzzing via wrapper.py (symlinked as harness).
set -eu

# --- Wait for entrypoint module's CPU allocation ---
ALLOC_FILE="/OSS_CRS_SHARED_DIR/cpu_allocation"
echo "Waiting for CPU allocation from entrypoint module..."
while [ ! -f "$ALLOC_FILE" ]; do sleep 1; done
source "$ALLOC_FILE"
echo "Got allocation: LIBFUZZER_CPUS=${LIBFUZZER_CPUS:-unset}"

HARNESS="${OSS_CRS_TARGET_HARNESS}"

# --- Download build output ---
libCRS download-build-output build-jazzer /out
export OUT=/out
export PATH="$OUT:$PATH"
cd "$OUT"

# --- /shared symlink (wrapper.py and supporting scripts hardcode /shared/) ---
SHARED="${OSS_CRS_SHARED_DIR:-/shared}"
if [ "$SHARED" != "/shared" ]; then
    rm -rf /shared 2>/dev/null || true
    ln -sfn "$SHARED" /shared
fi

# --- Setup directories ---
CRASH_DIR="/tmp/jazzer_crashes"
mkdir -p "$CRASH_DIR"

# Fuzzer sync dir in SHARED_DIR
SYNC_BASE="/OSS_CRS_SHARED_DIR/fuzzer_sync"
SYNC_DIR="${SYNC_BASE}/${OSS_CRS_TARGET}-${HARNESS}-0"
mkdir -p "$SYNC_DIR"

# Create corpus directories expected by wrapper.py
mkdir -p "$SYNC_DIR/jazzer-minimized/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy-kickstart/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy-kickstart-crashes/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy-permanence/queue"
mkdir -p "$SYNC_DIR/sync-quickseed/queue"
mkdir -p "$SYNC_DIR/nonsync-grammar-agent-explore/queue"
mkdir -p "$SYNC_DIR/nonsync-grammar-guy-fuzz/queue"
mkdir -p "$SYNC_DIR/nonsync-grammarroomba/queue"
mkdir -p "$SYNC_DIR/nonsync-discoguy/queue"
mkdir -p "$SYNC_DIR/nonsync-losan-gg/queue"
mkdir -p "$SYNC_DIR/sync-aijon-java/queue"
mkdir -p "$SYNC_DIR/sync-oss-crs-external/queue"

# Seed input dir: seeds fetched from other CRS
SEED_FETCH_DIR="/tmp/seeds_from_other_crs"
mkdir -p "$SEED_FETCH_DIR"

# --- Register PoV submission via libCRS ---
libCRS register-submit-dir pov "$CRASH_DIR" &

# --- Seed sharing ---
libCRS register-fetch-dir seed "$SEED_FETCH_DIR" &

# --- Map OSS-CRS env vars to Jazzer wrapper.py expected env vars ---
# (Jazzer uses ARTIPHISHELL_JAZZER_* not ARTIPHISHELL_LIBFUZZER_*)
# jazzer_driver searches for jazzer_standalone.jar in its own directory.
# The prebuild produces jazzer_agent_deploy.jar. Create symlink so driver finds it.
JAZZER_BUILD_DIR="$OUT/shellphish/jazzer-aixcc/jazzer-build"
if [ -f "$JAZZER_BUILD_DIR/jazzer_agent_deploy.jar" ] && [ ! -f "$JAZZER_BUILD_DIR/jazzer_standalone.jar" ]; then
    ln -s "$JAZZER_BUILD_DIR/jazzer_agent_deploy.jar" "$JAZZER_BUILD_DIR/jazzer_standalone.jar"
fi

export ARTIPHISHELL_JAZZER_CRASHING_SEEDS="$CRASH_DIR"
export ARTIPHISHELL_JAZZER_CRASH_REPORTS="/tmp/jazzer_crash_reports"
export ARTIPHISHELL_FUZZER_SYNC_PATH="$SYNC_DIR"
export ARTIPHISHELL_JAZZER_FUZZING_LOG="/tmp/fuzzer.log"
export ARTIPHISHELL_PROJECT_NAME="${OSS_CRS_TARGET:-unknown}"
export ARTIPHISHELL_HARNESS_NAME="$HARNESS"
export ARTIPHISHELL_HARNESS_INFO_ID="0"
mkdir -p "$CRASH_DIR" "/tmp/jazzer_crash_reports"

# Disable LeakSanitizer: leak detections are not actionable as PoVs.
export ASAN_OPTIONS="${ASAN_OPTIONS:+${ASAN_OPTIONS}:}detect_leaks=0"

# Container environment workarounds
echo core > /proc/sys/kernel/core_pattern 2>/dev/null || true

# --- Background: seed sharing monitor ---
(
    set +e
    while true; do
        sleep 10
        # Submit interesting corpus to other CRS
        if [ -d "$SYNC_DIR/jazzer-minimized/queue" ]; then
            for seed in "$SYNC_DIR/jazzer-minimized/queue"/*; do
                [ -f "$seed" ] || continue
                bn=$(basename "$seed")
                [ -f "/tmp/.seeds_submitted/$bn" ] && continue
                libCRS submit seed "$seed" 2>/dev/null || true
                mkdir -p /tmp/.seeds_submitted
                touch "/tmp/.seeds_submitted/$bn"
            done
        fi
        # Import fetched seeds into a sync dir that wrapper.py reads via -reload
        for seed in "$SEED_FETCH_DIR"/*; do
            [ -f "$seed" ] || continue
            bn=$(basename "$seed")
            mkdir -p "$SYNC_DIR/sync-oss-crs-external/queue"
            [ -f "$SYNC_DIR/sync-oss-crs-external/queue/$bn" ] || cp "$seed" "$SYNC_DIR/sync-oss-crs-external/queue/$bn" 2>/dev/null || true
        done
    done
) &

# --- Launch Jazzer ---
IFS=',' read -ra CORES <<< "$LIBFUZZER_CPUS"
NUM_CORES=${#CORES[@]}
CPUSET_RANGE="${CORES[0]}"
if [ "$NUM_CORES" -gt 1 ]; then
    CPUSET_RANGE="${CORES[0]}-${CORES[$((NUM_CORES-1))]}"
fi
echo "=== Jazzer: $NUM_CORES cores ($LIBFUZZER_CPUS), fork=$NUM_CORES ==="
exec taskset -c "$CPUSET_RANGE" "$OUT/$HARNESS" "-fork=$NUM_CORES"
