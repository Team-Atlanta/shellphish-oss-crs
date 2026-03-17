#!/bin/bash
# OSS-CRS glue: bridges libCRS build output transfer and PoV submission
# with Shellphish's run_fuzzer script.
set -eu

HARNESS="${OSS_CRS_TARGET_HARNESS}"

# --- Download build output ---
libCRS download-build-output build /out
export OUT=/out
export PATH="$OUT:$PATH"
export LD_LIBRARY_PATH="${OUT}:${LD_LIBRARY_PATH:-}"
cd "$OUT"

# --- Setup directories ---
POV_DIR="/tmp/povs"
mkdir -p "$POV_DIR"

# --- Register PoV submission (background watchdog) ---
libCRS register-submit-dir pov "$POV_DIR" &

# --- Map OSS-CRS env vars to ARTIPHISHELL env vars expected by run_fuzzer ---
export ARTIPHISHELL_PROJECT_NAME="${OSS_CRS_TARGET:-unknown}"
export ARTIPHISHELL_HARNESS_NAME="$HARNESS"
export ARTIPHISHELL_HARNESS_INFO_ID="0"
export ARTIPHISHELL_FUZZER_INSTANCE_NAME="main"
export ARTIPHISHELL_FUZZER_SYNC_DIR="/tmp/afl_sync"
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

# --- Run Shellphish's run_fuzzer ---
set +e
run_fuzzer "$HARNESS" &
FUZZ_PID=$!

# --- Crash monitor: copy crashes to PoV submission directory ---
CRASH_DIR="$ARTIPHISHELL_FUZZER_SYNC_DIR/main/crashes"

while kill -0 "$FUZZ_PID" 2>/dev/null; do
    if [ -d "$CRASH_DIR" ]; then
        for crash in "$CRASH_DIR"/id:*; do
            [ -f "$crash" ] || continue
            basename=$(basename "$crash")
            if [ ! -f "$POV_DIR/$basename" ]; then
                cp "$crash" "$POV_DIR/$basename" 2>/dev/null || true
            fi
        done
    fi
    sleep 5
done

# Final sweep
if [ -d "$CRASH_DIR" ]; then
    for crash in "$CRASH_DIR"/id:*; do
        [ -f "$crash" ] || continue
        basename=$(basename "$crash")
        [ -f "$POV_DIR/$basename" ] || cp "$crash" "$POV_DIR/$basename" 2>/dev/null || true
    done
fi

wait "$FUZZ_PID" || true
echo "Shellphish AFL++ fuzzer exited."
