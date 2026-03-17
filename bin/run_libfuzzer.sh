#!/bin/bash
# OSS-CRS glue for Shellphish LibFuzzer.
#
# wrapper.py (symlinked as the harness) writes crashes to
# ARTIPHISHELL_LIBFUZZER_CRASHING_SEEDS via artifact_prefix.
# libCRS register-submit-dir watches that directory and submits PoVs.
#
# If LIBFUZZER_CPUS is set (comma-separated core list, e.g. "10,11,12,13,14,15"),
# pins the LibFuzzer process to those cores and sets -fork=N (one worker per core).
# If not set, runs single-process (backward compatible).
set -eu

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
# wrapper.py sets artifact_prefix to this path; crashes written here
export ARTIPHISHELL_LIBFUZZER_CRASHING_SEEDS="$CRASH_DIR"
export ARTIPHISHELL_FUZZER_SYNC_PATH="$SYNC_DIR"
export ARTIPHISHELL_LIBFUZZER_FUZZING_LOG="/tmp/fuzzer.log"

# Container environment workarounds
echo core > /proc/sys/kernel/core_pattern 2>/dev/null || true
sysctl -w vm.mmap_rnd_bits=28 2>/dev/null || true

# --- Launch LibFuzzer ---
# wrapper.py accepts CLI args; -fork=N overrides the hardcoded fork=1
if [ -n "${LIBFUZZER_CPUS:-}" ]; then
    IFS=',' read -ra CORES <<< "$LIBFUZZER_CPUS"
    NUM_CORES=${#CORES[@]}
    # Build cpuset range for taskset
    CPUSET_RANGE="${CORES[0]}"
    if [ "$NUM_CORES" -gt 1 ]; then
        CPUSET_RANGE="${CORES[0]}-${CORES[$((NUM_CORES-1))]}"
    fi
    echo "=== LibFuzzer: $NUM_CORES cores ($LIBFUZZER_CPUS), fork=$NUM_CORES ==="
    exec taskset -c "$CPUSET_RANGE" "$OUT/$HARNESS" "-fork=$NUM_CORES"
else
    echo "=== LibFuzzer: single process ==="
    exec "$OUT/$HARNESS"
fi
