#!/bin/bash
# OSS-CRS entrypoint module: computes CPU allocation for all run modules
# and writes the result to SHARED_DIR for other containers to read.
#
# CRS_PIPELINE_MODE controls allocation strategy:
#   fuzzers (default) — split cores evenly between AFL++ and LibFuzzer
#   discoveryguy      — no fuzzer cores needed, all cores available for general use
#   aijon             — all fuzzer cores go to AFL++ (AIJON uses AFL++/IJON only)
set -euo pipefail

ALLOC_FILE="/OSS_CRS_SHARED_DIR/cpu_allocation"
MODE="${CRS_PIPELINE_MODE:-fuzzers}"

# Read available cores from cgroup cpuset
if [ -f /sys/fs/cgroup/cpuset.cpus.effective ]; then
    CPUSET=$(cat /sys/fs/cgroup/cpuset.cpus.effective)
elif [ -f /sys/fs/cgroup/cpuset/cpuset.cpus ]; then
    CPUSET=$(cat /sys/fs/cgroup/cpuset/cpuset.cpus)
else
    # Fallback: use nproc and assume cores 0..N-1
    N=$(nproc)
    CPUSET="0-$((N-1))"
fi

# Parse cpuset string (e.g. "4-15" or "4,5,6,7,8,9,10,11,12,13,14,15") into array
parse_cpuset() {
    local result=()
    IFS=',' read -ra parts <<< "$1"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            IFS='-' read -r start end <<< "$part"
            for ((i=start; i<=end; i++)); do
                result+=("$i")
            done
        else
            result+=("$part")
        fi
    done
    echo "${result[@]}"
}

CORES=($(parse_cpuset "$CPUSET"))
TOTAL=${#CORES[@]}

# Format as comma-separated strings
join_cores() { local IFS=','; echo "$*"; }
ALL_CPUS=$(join_cores "${CORES[@]}")

echo "=== Entrypoint: CPU Allocation (mode=$MODE) ==="
echo "Available cores: $CPUSET ($TOTAL total)"

case "$MODE" in
    discoveryguy)
        # DiscoveryGuy is LLM-driven, does not run fuzzers — no core pinning needed.
        # Write a valid allocation file so other containers that wait for it don't hang,
        # but the values are unused. DiscoveryGuy runs on all available cores unbound.
        AFLPP_CPUS=""
        LIBFUZZER_CPUS=""
        echo "Mode: discoveryguy — skipping fuzzer core allocation (no fuzzers in this pipeline)"
        ;;
    aijon)
        # AIJON pipeline: AIJON fuzzer (half) + coverage tracer (1) + AFL++ (rest).
        # Minimum 3 cores required.
        if [ "$TOTAL" -lt 3 ]; then
            echo "ERROR: AIJON pipeline requires at least 3 cores, got $TOTAL"
            exit 1
        fi
        HALF=$((TOTAL / 2))
        AIJON_CORES=("${CORES[@]:0:$HALF}")
        AIJON_CPUS=$(join_cores "${AIJON_CORES[@]}")
        # 1 core for coverage tracer, rest for AFL++
        AFLPP_CORES=("${CORES[@]:$((HALF + 1))}")
        AFLPP_CPUS=$(join_cores "${AFLPP_CORES[@]}")
        LIBFUZZER_CPUS=""
        echo "Mode: aijon — AIJON: ${AIJON_CPUS} (${#AIJON_CORES[@]} cores), coverage: ${CORES[$HALF]}, AFL++: ${AFLPP_CPUS} (${#AFLPP_CORES[@]} cores)"
        ;;
    *)
        # Default: split evenly between AFL++ and LibFuzzer
        HALF=$((TOTAL / 2))
        AFLPP_CORES=("${CORES[@]:0:$HALF}")
        LIBFUZZER_CORES=("${CORES[@]:$HALF}")
        AFLPP_CPUS=$(join_cores "${AFLPP_CORES[@]}")
        LIBFUZZER_CPUS=$(join_cores "${LIBFUZZER_CORES[@]}")
        echo "Mode: fuzzers — AFL++: ${#AFLPP_CORES[@]} cores, LibFuzzer: ${#LIBFUZZER_CORES[@]} cores"
        ;;
esac

echo "AFLPP_CPUS=$AFLPP_CPUS"
echo "LIBFUZZER_CPUS=$LIBFUZZER_CPUS"
echo "==================================="

# Write allocation file atomically: write to temp, then mv (atomic on same filesystem)
ALLOC_TMP="${ALLOC_FILE}.tmp"
cat > "$ALLOC_TMP" <<EOF
AFLPP_CPUS=$AFLPP_CPUS
LIBFUZZER_CPUS=$LIBFUZZER_CPUS
AIJON_CPUS=${AIJON_CPUS:-}
EOF
mv "$ALLOC_TMP" "$ALLOC_FILE"

echo "Allocation written to $ALLOC_FILE"

# Keep alive — OSS-CRS Compose shuts down all containers when any exits
exec sleep infinity
