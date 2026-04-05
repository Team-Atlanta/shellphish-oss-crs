#!/bin/bash
# OSS-CRS glue for Shellphish Jazzer.
#
# Launches N independent Jazzer single-process instances (one per core),
# each with its own corpus directory. A background loop syncs corpus between
# instances into jazzer-minimized/queue/ and submits seeds/PoVs via libCRS.
#
# Why not -fork=N: fork mode's parent process can't see Java bytecode
# coverage (Jazzer agent registers counters in child address space).
# Result: cov=0, ft=0, corp=0 — pure random mutation, no coverage feedback.
# Single-process mode lets Jazzer agent feed coverage back to libFuzzer.
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

# --- Per-instance corpus directories ---
IFS=',' read -ra CORES <<< "$LIBFUZZER_CPUS"
NUM_CORES=${#CORES[@]}

for i in "${!CORES[@]}"; do
    mkdir -p "$SYNC_DIR/instance_${i}/queue"
done

# --- Background: corpus sync + seed sharing + external import ---
(
    set +e
    while true; do
        sleep 10

        # 1. Sync: copy new corpus from each instance to jazzer-minimized/queue/
        #    This is the simplified version of minimize_corpus_and_same_node_sync.sh.
        #    We copy rather than merge — dedup by filename is sufficient for sharing.
        for idir in "$SYNC_DIR"/instance_*/queue; do
            [ -d "$idir" ] || continue
            for seed in "$idir"/*; do
                [ -f "$seed" ] || continue
                bn=$(basename "$seed")
                [ -f "$SYNC_DIR/jazzer-minimized/queue/$bn" ] || \
                    cp "$seed" "$SYNC_DIR/jazzer-minimized/queue/$bn" 2>/dev/null || true
            done
        done

        # 2. Submit seeds from jazzer-minimized to other CRS
        for seed in "$SYNC_DIR/jazzer-minimized/queue"/*; do
            [ -f "$seed" ] || continue
            bn=$(basename "$seed")
            [ -f "/tmp/.seeds_submitted/$bn" ] && continue
            libCRS submit seed "$seed" 2>/dev/null || true
            mkdir -p /tmp/.seeds_submitted
            touch "/tmp/.seeds_submitted/$bn"
        done

        # 3. Import fetched seeds into sync-oss-crs-external for all instances to read
        for seed in "$SEED_FETCH_DIR"/*; do
            [ -f "$seed" ] || continue
            bn=$(basename "$seed")
            [ -f "$SYNC_DIR/sync-oss-crs-external/queue/$bn" ] || \
                cp "$seed" "$SYNC_DIR/sync-oss-crs-external/queue/$bn" 2>/dev/null || true
        done
    done
) &

# --- Launch N independent Jazzer instances (single-process, no fork) ---
echo "=== Jazzer: $NUM_CORES independent instances (cores: $LIBFUZZER_CPUS) ==="
set +e

# Launch secondary instances in background (instance 1..N-1)
for i in "${!CORES[@]}"; do
    [ "$i" -eq 0 ] && continue  # skip instance 0, will run as foreground
    CORE=${CORES[$i]}
    INSTANCE_CORPUS="$SYNC_DIR/instance_${i}/queue"
    echo "Starting Jazzer instance $i on core $CORE (background)"
    taskset -c "$CORE" "$OUT/$HARNESS" \
        "$INSTANCE_CORPUS" \
        "$SYNC_DIR/jazzer-minimized/queue" \
        "$SYNC_DIR/sync-quickseed/queue" \
        "$SYNC_DIR/sync-corpusguy/queue" \
        "$SYNC_DIR/sync-oss-crs-external/queue" &
done

# Launch instance 0 as foreground process (exec replaces bash).
# When oss-crs timeout kills the container, docker stop sends SIGTERM to PID 1.
# Since PID 1 IS the Jazzer process (via exec), it terminates immediately.
# Container exit → --abort-on-container-exit stops everything.
CORE=${CORES[0]}
INSTANCE_CORPUS="$SYNC_DIR/instance_0/queue"
echo "Starting Jazzer instance 0 on core $CORE (foreground, exec)"
exec taskset -c "$CORE" "$OUT/$HARNESS" \
    "$INSTANCE_CORPUS" \
    "$SYNC_DIR/jazzer-minimized/queue" \
    "$SYNC_DIR/sync-quickseed/queue" \
    "$SYNC_DIR/sync-corpusguy/queue" \
    "$SYNC_DIR/sync-oss-crs-external/queue"
