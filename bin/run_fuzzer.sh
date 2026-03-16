#!/bin/bash
# run_fuzzer.sh: Download AFL++ build output, run afl-fuzz, submit crashes as PoVs.
#
# This is the glue between AFL++'s fuzzing runtime and OSS-CRS's run phase.
# Simplified single-instance runner for Phase 1 (no multi-node sync, no nautilus).

set -eu

HARNESS="${OSS_CRS_TARGET_HARNESS}"

# --- Download build output ---
libCRS download-build-output build /out
export OUT=/out
export PATH="$OUT:$PATH"
cd "$OUT"

# --- Setup directories ---
SYNC_DIR="/tmp/afl_sync"
CORPUS_DIR="/tmp/corpus"
POV_DIR="/tmp/povs"
mkdir -p "$SYNC_DIR" "$CORPUS_DIR" "$POV_DIR"

# --- Seed corpus ---
SEED_CORPUS="$OUT/${HARNESS}_seed_corpus.zip"
if [ -f "$SEED_CORPUS" ]; then
    echo "Extracting seed corpus: $SEED_CORPUS"
    unzip -o -d "$CORPUS_DIR/" "$SEED_CORPUS" > /dev/null 2>&1 || true
fi

# Also check for unzipped seed corpus directory
SEED_DIR="$OUT/${HARNESS}_seed_corpus"
if [ -d "$SEED_DIR" ]; then
    cp "$SEED_DIR"/* "$CORPUS_DIR/" 2>/dev/null || true
fi

# AFL++ requires at least 1 input file
if [ -z "$(ls -A "$CORPUS_DIR" 2>/dev/null)" ]; then
    echo "input" > "$CORPUS_DIR/input"
fi

# --- Register PoV submission (background daemon) ---
libCRS register-submit-dir pov "$POV_DIR" &

# --- AFL++ runtime environment ---
export AFL_NO_AFFINITY=1
export AFL_FAST_CAL=1
export AFL_FORKSRV_INIT_TMOUT=30000
export AFL_MAP_SIZE=2621440
export AFL_IGNORE_UNKNOWN_ENVS=1

export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_odr_violation=0"
export MSAN_OPTIONS="exit_code=86:symbolize=0"
export UBSAN_OPTIONS="symbolize=0"

# Allow kernel tuning (containers run privileged in OSS-CRS)
sysctl -w vm.mmap_rnd_bits=28 2>/dev/null || true

# --- Dictionary ---
DICT_ARGS=""
if [ -f "$OUT/afl++.dict" ]; then
    DICT_ARGS="-x $OUT/afl++.dict"
fi

# Per-harness dictionary
if [ -f "$OUT/${HARNESS}.dict" ]; then
    DICT_ARGS="-x $OUT/${HARNESS}.dict"
fi

# --- Build afl-fuzz command ---
# Single main instance, timeout 5000ms (Shellphish default for main)
AFL_CMD="$OUT/afl-fuzz -M main -t 5000 -i $CORPUS_DIR -o $SYNC_DIR $DICT_ARGS -- $OUT/$HARNESS"

echo "=== AFL++ fuzzer starting ==="
echo "Harness: $HARNESS"
echo "Command: $AFL_CMD"
echo "==========================="

# --- Start fuzzing in background ---
set +e
$AFL_CMD &
FUZZ_PID=$!

# --- Crash monitor: copy crashes to PoV submission directory ---
CRASH_DIR="$SYNC_DIR/main/crashes"

while kill -0 "$FUZZ_PID" 2>/dev/null; do
    if [ -d "$CRASH_DIR" ]; then
        for crash in "$CRASH_DIR"/id:*; do
            [ -f "$crash" ] || continue
            basename=$(basename "$crash")
            # Only copy if not already submitted
            if [ ! -f "$POV_DIR/$basename" ]; then
                cp "$crash" "$POV_DIR/$basename" 2>/dev/null || true
            fi
        done
    fi
    sleep 5
done

# Final sweep for any remaining crashes
if [ -d "$CRASH_DIR" ]; then
    for crash in "$CRASH_DIR"/id:*; do
        [ -f "$crash" ] || continue
        basename=$(basename "$crash")
        [ -f "$POV_DIR/$basename" ] || cp "$crash" "$POV_DIR/$basename" 2>/dev/null || true
    done
fi

wait "$FUZZ_PID" || true
echo "AFL++ fuzzer exited."
