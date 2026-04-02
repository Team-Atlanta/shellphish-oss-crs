#!/bin/bash
# OSS-CRS entrypoint module: computes CPU allocation for all run modules
# and writes the result to SHARED_DIR for other containers to read.
#
# CRS_PIPELINE_MODE controls allocation strategy:
#   fuzzers (default) — split cores evenly between AFL++ and LibFuzzer
#   aflpp-only        — all cores to AFL++, no LibFuzzer
#   libfuzzer-only    — all cores to LibFuzzer, no AFL++
#   grammar           — most cores to AFL++, 1-2 for other components
#   discoveryguy      — same as grammar (AFL++ consumes DG-generated seeds)
#   aijon             — AIJON half, coverage 1, AFL++ rest
#   jvm-fuzzers       — all cores to Jazzer (LibFuzzer), no AFL++
#   quickseed         — most cores to Jazzer, 1-2 shared (QuickSeed/neo4j/LLM)
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
    grammar)
        # Grammar pipeline: AFL++ is the only fuzzer. Other components (Grammar-Guy,
        # Roomba, coverage tracers, neo4j) are I/O bound or bursty — share a small
        # set of cores. Give the rest to AFL++.
        # Minimum 2 cores: 1 AFL++ + 1 shared.
        if [ "$TOTAL" -lt 2 ]; then
            echo "ERROR: Grammar pipeline requires at least 2 cores, got $TOTAL"
            exit 1
        fi
        if [ "$TOTAL" -lt 4 ]; then
            SHARED=1
        else
            SHARED=2
        fi
        AFLPP_CORES=("${CORES[@]:0:$((TOTAL - SHARED))}")
        AFLPP_CPUS=$(join_cores "${AFLPP_CORES[@]}")
        LIBFUZZER_CPUS=""
        SHARED_CORES=("${CORES[@]:$((TOTAL - SHARED))}")
        echo "Mode: grammar — AFL++: ${AFLPP_CPUS} (${#AFLPP_CORES[@]} cores), shared (tracers/neo4j/LLM): $(join_cores "${SHARED_CORES[@]}") ($SHARED cores)"
        ;;
    discoveryguy)
        # DiscoveryGuy pipeline: AFL++ consumes DG-generated seeds. DiscoveryGuy
        # itself is LLM-driven (I/O bound). Same allocation as grammar.
        # Minimum 2 cores: 1 AFL++ + 1 shared.
        if [ "$TOTAL" -lt 2 ]; then
            echo "ERROR: DiscoveryGuy pipeline requires at least 2 cores, got $TOTAL"
            exit 1
        fi
        if [ "$TOTAL" -lt 4 ]; then
            SHARED=1
        else
            SHARED=2
        fi
        AFLPP_CORES=("${CORES[@]:0:$((TOTAL - SHARED))}")
        AFLPP_CPUS=$(join_cores "${AFLPP_CORES[@]}")
        LIBFUZZER_CPUS=""
        SHARED_CORES=("${CORES[@]:$((TOTAL - SHARED))}")
        echo "Mode: discoveryguy — AFL++: ${AFLPP_CPUS} (${#AFLPP_CORES[@]} cores), shared (neo4j/LLM): $(join_cores "${SHARED_CORES[@]}") ($SHARED cores)"
        ;;
    aflpp-only)
        # AFL++ only pipeline: all cores to AFL++, no LibFuzzer.
        AFLPP_CPUS="$ALL_CPUS"
        LIBFUZZER_CPUS=""
        echo "Mode: aflpp-only — AFL++: ${AFLPP_CPUS} ($TOTAL cores), LibFuzzer: none"
        ;;
    libfuzzer-only)
        # LibFuzzer only pipeline: all cores to LibFuzzer, no AFL++.
        AFLPP_CPUS=""
        LIBFUZZER_CPUS="$ALL_CPUS"
        echo "Mode: libfuzzer-only — LibFuzzer: ${LIBFUZZER_CPUS} ($TOTAL cores), AFL++: none"
        ;;
    jvm-fuzzers)
        # JVM fuzzers pipeline: Jazzer only, no AFL++.
        # All cores go to Jazzer (LibFuzzer-based, uses fork=N).
        AFLPP_CPUS=""
        LIBFUZZER_CPUS="$ALL_CPUS"
        echo "Mode: jvm-fuzzers — Jazzer (LibFuzzer): ${LIBFUZZER_CPUS} ($TOTAL cores), AFL++: none"
        ;;
    quickseed)
        # QuickSeed pipeline: Jazzer is the only fuzzer. QuickSeed is LLM/IO-bound,
        # shares 1-2 cores with neo4j/ag-init/codeql-server.
        # Minimum 2 cores: 1 Jazzer + 1 shared.
        if [ "$TOTAL" -lt 2 ]; then
            echo "ERROR: QuickSeed pipeline requires at least 2 cores, got $TOTAL"
            exit 1
        fi
        if [ "$TOTAL" -lt 4 ]; then
            SHARED=1
        else
            SHARED=2
        fi
        LIBFUZZER_CORES=("${CORES[@]:0:$((TOTAL - SHARED))}")
        LIBFUZZER_CPUS=$(join_cores "${LIBFUZZER_CORES[@]}")
        AFLPP_CPUS=""
        SHARED_CORES=("${CORES[@]:$((TOTAL - SHARED))}")
        echo "Mode: quickseed — Jazzer (LibFuzzer): ${LIBFUZZER_CPUS} (${#LIBFUZZER_CORES[@]} cores), shared (QuickSeed/neo4j/LLM): $(join_cores "${SHARED_CORES[@]}") ($SHARED cores)"
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
