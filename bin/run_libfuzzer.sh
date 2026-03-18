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
SYNC_DIR="/tmp/libfuzzer_sync"
mkdir -p "$CRASH_DIR" "$SYNC_DIR"
# Create corpus directories expected by wrapper.py
mkdir -p "$SYNC_DIR/libfuzzer-minimized/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy-kickstart/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy-kickstart-crashes/queue"
mkdir -p "$SYNC_DIR/sync-corpusguy-permanence/queue"
mkdir -p "$SYNC_DIR/nonsync-grammar-agent-explore/queue"
mkdir -p "$SYNC_DIR/nonsync-grammar-guy-fuzz/queue"
mkdir -p "$SYNC_DIR/nonsync-grammarroomba/queue"
mkdir -p "$SYNC_DIR/nonsync-discoguy/queue"

# --- Register PoV submission via libCRS ---
libCRS register-submit-dir pov "$CRASH_DIR" &

# --- Map OSS-CRS env vars to wrapper.py expected env vars ---
export ARTIPHISHELL_LIBFUZZER_CRASHING_SEEDS="$CRASH_DIR"
export ARTIPHISHELL_FUZZER_SYNC_PATH="$SYNC_DIR"
export ARTIPHISHELL_LIBFUZZER_FUZZING_LOG="/tmp/fuzzer.log"

# Container environment workarounds
echo core > /proc/sys/kernel/core_pattern 2>/dev/null || true
sysctl -w vm.mmap_rnd_bits=28 2>/dev/null || true

# --- Launch LibFuzzer ---
IFS=',' read -ra CORES <<< "$LIBFUZZER_CPUS"
NUM_CORES=${#CORES[@]}
CPUSET_RANGE="${CORES[0]}"
if [ "$NUM_CORES" -gt 1 ]; then
    CPUSET_RANGE="${CORES[0]}-${CORES[$((NUM_CORES-1))]}"
fi
echo "=== LibFuzzer: $NUM_CORES cores ($LIBFUZZER_CPUS), fork=$NUM_CORES ==="
exec taskset -c "$CPUSET_RANGE" "$OUT/$HARNESS" "-fork=$NUM_CORES"
