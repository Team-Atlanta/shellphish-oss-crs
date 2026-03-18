#!/bin/bash
# OSS-CRS entrypoint module: computes CPU allocation for all run modules
# and writes the result to SHARED_DIR for other containers to read.
set -euo pipefail

ALLOC_FILE="/OSS_CRS_SHARED_DIR/cpu_allocation"

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

# Split evenly between AFL++ and LibFuzzer
HALF=$((TOTAL / 2))
AFLPP_CORES=("${CORES[@]:0:$HALF}")
LIBFUZZER_CORES=("${CORES[@]:$HALF}")

# Format as comma-separated strings
join_cores() { local IFS=','; echo "$*"; }
AFLPP_CPUS=$(join_cores "${AFLPP_CORES[@]}")
LIBFUZZER_CPUS=$(join_cores "${LIBFUZZER_CORES[@]}")

echo "=== Entrypoint: CPU Allocation ==="
echo "Available cores: $CPUSET ($TOTAL total)"
echo "AFL++:     $AFLPP_CPUS (${#AFLPP_CORES[@]} cores)"
echo "LibFuzzer: $LIBFUZZER_CPUS (${#LIBFUZZER_CORES[@]} cores)"
echo "==================================="

# Write allocation file atomically: write to temp, then mv (atomic on same filesystem)
ALLOC_TMP="${ALLOC_FILE}.tmp"
cat > "$ALLOC_TMP" <<EOF
AFLPP_CPUS=$AFLPP_CPUS
LIBFUZZER_CPUS=$LIBFUZZER_CPUS
EOF
mv "$ALLOC_TMP" "$ALLOC_FILE"

echo "Allocation written to $ALLOC_FILE"
