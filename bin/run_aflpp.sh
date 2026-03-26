#!/bin/bash
# OSS-CRS glue for Shellphish AFL++.
#
# Reads AFLPP_CPUS from entrypoint module's allocation file (SHARED_DIR/cpu_allocation).
# Launches one AFL++ instance per core: 1 main + N-1 secondaries, each pinned via taskset.
#
# Shellphish's run_fuzzer script handles per-instance strategy selection:
# main gets fixed config (timeout 5000, no cmplog/dict), secondaries get
# randomized strategies (varying timeout, cmplog, dict, queue shuffling).
set -eu

# --- Wait for entrypoint module's CPU allocation ---
ALLOC_FILE="/OSS_CRS_SHARED_DIR/cpu_allocation"
echo "Waiting for CPU allocation from entrypoint module..."
while [ ! -f "$ALLOC_FILE" ]; do sleep 1; done
source "$ALLOC_FILE"
echo "Got allocation: AFLPP_CPUS=${AFLPP_CPUS:-unset}"

HARNESS="${OSS_CRS_TARGET_HARNESS}"

# --- Download build output ---
libCRS download-build-output build-aflpp /out
export OUT=/out
export PATH="$OUT:$PATH"
export LD_LIBRARY_PATH="${OUT}:${LD_LIBRARY_PATH:-}"
cd "$OUT"

# --- Setup directories ---
POV_DIR="/tmp/povs"
mkdir -p "$POV_DIR"

# Fuzzer sync dir in SHARED_DIR so other run modules can access it
# (Grammar-Composer, GrammarRoomba etc. read/write grammars and seeds here)
SYNC_BASE="/OSS_CRS_SHARED_DIR/fuzzer_sync"
SYNC_DIR="${SYNC_BASE}/${OSS_CRS_TARGET}-${HARNESS}-0"
mkdir -p "$SYNC_DIR"

# Seed input dir: other CRS's seeds fetched here, AFL++ reads via -F
SEED_FETCH_DIR="/tmp/seeds_from_other_crs"
mkdir -p "$SEED_FETCH_DIR"

# --- Register PoV submission (background watchdog) ---
libCRS register-submit-dir pov "$POV_DIR" &

# --- Seed sharing ---
# Fetch seeds from other CRS
libCRS register-fetch-dir seed "$SEED_FETCH_DIR" &
# Seed submission done via direct libCRS submit in collect loop below

# --- Common env vars for Shellphish's run_fuzzer ---
export ARTIPHISHELL_PROJECT_NAME="${OSS_CRS_TARGET:-unknown}"
export ARTIPHISHELL_HARNESS_NAME="$HARNESS"
export ARTIPHISHELL_HARNESS_INFO_ID="0"
export ARTIPHISHELL_FUZZER_SYNC_DIR="$SYNC_DIR"
export ARTIPHISHELL_INTER_HARNESS_SYNC_DIR="/tmp/foreign_fuzzer"
export ARTIPHISHELL_AFL_EXTRA_ARGS=""
export ARTIPHISHELL_AFL_TIMEOUT=""
export ARTIPHISHELL_CCACHE_DISABLE=1
export FUZZING_ENGINE="shellphish_aflpp"
export RUN_FUZZER_MODE="interactive"
export SANITIZER="${SANITIZER:-address}"

# AFL++ container environment workarounds
export AFL_SKIP_CPUFREQ=1
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
echo core > /proc/sys/kernel/core_pattern 2>/dev/null || true
sysctl -w vm.mmap_rnd_bits=28 2>/dev/null || true

mkdir -p "$ARTIPHISHELL_FUZZER_SYNC_DIR" "$ARTIPHISHELL_INTER_HARNESS_SYNC_DIR"

# --- Launch AFL++ instances ---
set +e
PIDS=""

IFS=',' read -ra CORES <<< "$AFLPP_CPUS"
NUM_CORES=${#CORES[@]}
echo "=== AFL++ multi-instance: $NUM_CORES cores (${AFLPP_CPUS}) ==="

for i in "${!CORES[@]}"; do
    CORE=${CORES[$i]}
    if [ "$i" -eq 0 ]; then
        INSTANCE_NAME="main"
    else
        INSTANCE_NAME="secondary_${i}"
    fi
    echo "Starting AFL++ instance '$INSTANCE_NAME' on core $CORE"
    export ARTIPHISHELL_FUZZER_INSTANCE_NAME="$INSTANCE_NAME"
    taskset -c "$CORE" run_fuzzer "$HARNESS" &
    PIDS="$PIDS $!"
done

# --- Crash + seed monitor ---
collect_crashes_and_seeds() {
    # Collect crashes from ALL instances
    for instance_dir in "$ARTIPHISHELL_FUZZER_SYNC_DIR"/*/crashes; do
        [ -d "$instance_dir" ] || continue
        for crash in "$instance_dir"/id:*; do
            [ -f "$crash" ] || continue
            bn=$(basename "$crash")
            [ -f "$POV_DIR/$bn" ] || cp "$crash" "$POV_DIR/$bn" 2>/dev/null || true
        done
    done
    # Submit seeds from main instance queue to other CRS
    MAIN_QUEUE="$ARTIPHISHELL_FUZZER_SYNC_DIR/main/queue"
    if [ -d "$MAIN_QUEUE" ]; then
        for seed in "$MAIN_QUEUE"/id:*; do
            [ -f "$seed" ] || continue
            bn=$(basename "$seed")
            # Track submitted seeds to avoid duplicates
            [ -f "/tmp/.seeds_submitted/$bn" ] && continue
            libCRS submit seed "$seed" 2>/dev/null || true
            mkdir -p /tmp/.seeds_submitted
            touch "/tmp/.seeds_submitted/$bn"
        done
    fi
    # Import fetched seeds from other CRS into AFL++ foreign sync
    for seed in "$SEED_FETCH_DIR"/*; do
        [ -f "$seed" ] || continue
        bn=$(basename "$seed")
        mkdir -p "$ARTIPHISHELL_INTER_HARNESS_SYNC_DIR/queue"
        [ -f "$ARTIPHISHELL_INTER_HARNESS_SYNC_DIR/queue/$bn" ] || cp "$seed" "$ARTIPHISHELL_INTER_HARNESS_SYNC_DIR/queue/$bn" 2>/dev/null || true
    done
}

# Monitor while any fuzzer is alive
while true; do
    ALIVE=false
    for pid in $PIDS; do
        kill -0 "$pid" 2>/dev/null && ALIVE=true
    done
    $ALIVE || break
    collect_crashes_and_seeds
    sleep 5
done

# Final sweep
collect_crashes_and_seeds

wait || true
echo "AFL++ fuzzer(s) exited."
