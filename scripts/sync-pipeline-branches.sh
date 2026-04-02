#!/bin/bash
# Sync all pipeline branches with the latest main.
# Each pipeline branch = main + its own crs.yaml (the only difference).
# This script recreates each branch from main HEAD, adds the crs.yaml,
# and force-pushes. Result: each branch is exactly 1 commit ahead of main.
#
# Usage: ./scripts/sync-pipeline-branches.sh [--dry-run]
set -euo pipefail

# Map: branch name → crs.yaml source file
declare -A BRANCH_CONFIG=(
    [crs-shellphish-c-fuzzers-aflpp]=oss-crs/crs-c-fuzzers-aflpp.yaml
    [crs-shellphish-c-fuzzers-libfuzzer]=oss-crs/crs-c-fuzzers-libfuzzer.yaml
    [crs-shellphish-discoveryguy]=oss-crs/crs-discoveryguy.yaml
    [crs-shellphish-aijon]=oss-crs/crs-aijon.yaml
    [crs-shellphish-grammar]=oss-crs/crs-grammar.yaml
    [crs-shellphish-jvm-fuzzers]=oss-crs/crs-jvm-fuzzers.yaml
    [crs-shellphish-quickseed]=oss-crs/crs-quickseed.yaml
)

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

ORIG_BRANCH=$(git rev-parse --abbrev-ref HEAD)

echo "=== Updating main ==="
git checkout main
git pull origin main
MAIN_HEAD=$(git rev-parse --short HEAD)
echo "main at $MAIN_HEAD"

FAILED=()
for BRANCH in "${!BRANCH_CONFIG[@]}"; do
    CONFIG="${BRANCH_CONFIG[$BRANCH]}"
    echo ""
    echo "=== $BRANCH (config: $CONFIG) ==="

    if [ ! -f "$CONFIG" ]; then
        echo "  SKIP: $CONFIG not found"
        FAILED+=("$BRANCH ($CONFIG missing)")
        continue
    fi

    # Create/reset branch to main HEAD
    git checkout -B "$BRANCH" main

    # Add crs.yaml
    cp "$CONFIG" oss-crs/crs.yaml
    git add -f oss-crs/crs.yaml
    git commit -m "add crs.yaml for $BRANCH pipeline"

    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] Would force-push $BRANCH (1 commit ahead of main)"
    else
        git push origin "$BRANCH" --force-with-lease
        echo "  Pushed $BRANCH (1 commit ahead of $MAIN_HEAD)"
    fi
done

git checkout "$ORIG_BRANCH"

echo ""
echo "=== Done ==="
echo "main: $MAIN_HEAD"
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "FAILED:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
else
    echo "All ${#BRANCH_CONFIG[@]} branches synced (each 1 commit ahead of main)."
fi
