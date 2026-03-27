#!/bin/bash
# OSS-CRS glue for Shellphish LibFuzzer.
#
# Reads LIBFUZZER_CPUS from entrypoint module's allocation file (SHARED_DIR/cpu_allocation).
# Pins LibFuzzer to allocated cores and sets -fork=N (one worker per core).
#
# wrapper.py (symlinked as the harness) writes crashes to
# ARTIPHISHELL_LIBFUZZER_CRASHING_SEEDS via artifact_prefix.
# libCRS register-submit-dir watches that directory and submits PoVs.
set -eu

# --- Wait for entrypoint module's CPU allocation ---
ALLOC_FILE="/OSS_CRS_SHARED_DIR/cpu_allocation"
echo "Waiting for CPU allocation from entrypoint module..."
while [ ! -f "$ALLOC_FILE" ]; do sleep 1; done
source "$ALLOC_FILE"
echo "Got allocation: LIBFUZZER_CPUS=${LIBFUZZER_CPUS:-unset}"

HARNESS="${OSS_CRS_TARGET_HARNESS}"

# --- Download build output ---
libCRS download-build-output build-libfuzzer /out
export OUT=/out
export PATH="$OUT:$PATH"
cd "$OUT"

# --- Setup directories ---
CRASH_DIR="/tmp/libfuzzer_crashes"
mkdir -p "$CRASH_DIR"

# Fuzzer sync dir in SHARED_DIR so other run modules can access it
# (Grammar-Composer, GrammarRoomba etc. read/write grammars and seeds here)
SYNC_BASE="/OSS_CRS_SHARED_DIR/fuzzer_sync"
SYNC_DIR="${SYNC_BASE}/${OSS_CRS_TARGET}-${HARNESS}-0"
mkdir -p "$SYNC_DIR"

# Create corpus directories expected by wrapper.py and seed generators
mkdir -p "$SYNC_DIR/libfuzzer-minimized/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy-kickstart/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy-kickstart-crashes/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy-permanence/queue"
mkdir -p "$SYNC_DIR/nonsync-grammar-agent-explore/queue"
mkdir -p "$SYNC_DIR/nonsync-grammar-guy-fuzz/queue"
mkdir -p "$SYNC_DIR/nonsync-grammarroomba/queue"
mkdir -p "$SYNC_DIR/nonsync-discoguy/queue"

# Seed input dir: seeds fetched from other CRS
SEED_FETCH_DIR="/tmp/seeds_from_other_crs"
mkdir -p "$SEED_FETCH_DIR"

# --- Register PoV submission via libCRS ---
libCRS register-submit-dir pov "$CRASH_DIR" &

# --- Seed sharing ---
# Fetch seeds from other CRS
libCRS register-fetch-dir seed "$SEED_FETCH_DIR" &
# Seed submission done via direct libCRS submit in background monitor below

# --- Map OSS-CRS env vars to wrapper.py expected env vars ---
export ARTIPHISHELL_LIBFUZZER_CRASHING_SEEDS="$CRASH_DIR"
export ARTIPHISHELL_FUZZER_SYNC_PATH="$SYNC_DIR"
export ARTIPHISHELL_LIBFUZZER_FUZZING_LOG="/tmp/fuzzer.log"

# Container environment workarounds
echo core > /proc/sys/kernel/core_pattern 2>/dev/null || true
sysctl -w vm.mmap_rnd_bits=28 2>/dev/null || true

# --- Background: seed sharing monitor ---
# Periodically copy LibFuzzer corpus to seed submit dir and import fetched seeds
(
    set +e  # glob on empty dirs returns literal '*', which fails under -e
    while true; do
        sleep 10
        # Submit interesting corpus to other CRS
        if [ -d "$SYNC_DIR/libfuzzer-minimized/queue" ]; then
            for seed in "$SYNC_DIR/libfuzzer-minimized/queue"/*; do
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

# --- Launch LibFuzzer ---
IFS=',' read -ra CORES <<< "$LIBFUZZER_CPUS"
NUM_CORES=${#CORES[@]}
CPUSET_RANGE="${CORES[0]}"
if [ "$NUM_CORES" -gt 1 ]; then
    CPUSET_RANGE="${CORES[0]}-${CORES[$((NUM_CORES-1))]}"
fi
echo "=== LibFuzzer: $NUM_CORES cores ($LIBFUZZER_CPUS), fork=$NUM_CORES ==="
exec taskset -c "$CPUSET_RANGE" "$OUT/$HARNESS" "-fork=$NUM_CORES"
