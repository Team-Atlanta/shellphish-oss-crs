# AFL++

AFL++ is a well-known coverage-guided fuzzer that the CRS uses as its primary fuzzing engine. The integration includes custom corpus synchronization, grammar support via Nautilus, CMPLOG mode for comparison-guided fuzzing, and sophisticated multi-node orchestration for distributed fuzzing campaigns.

## Purpose

- Coverage-guided mutation fuzzing with grammar support
- Distributed fuzzing across multiple Kubernetes nodes
- Primary fuzzing engine for C/C++ targets
- CMPLOG mode for complex comparison breaking
- Cross-node corpus synchronization

## Integration Approach

AFL++ is a well-known tool. The CRS integration focuses on:
1. **Custom fuzzer wrapper** for auto-restart and corpus recovery
2. **Cross-node synchronization** via SSH-based rsync
3. **Grammar integration** with Nautilus mutator
4. **Multi-instance coordination** (main replicant + secondaries)
5. **Crash injection** to all fuzzer instances

## Pipeline Configuration

**File**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml)

### Key Tasks

1. **`aflpp_build`** ([Lines 36-127](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L36-L127))
   - Builds AFL++ instrumented binaries
   - Uses `shellphish_aflpp` instrumentation mode
   - Resource limits: 6-10 CPU, 26-40Gi memory
   - Timeout: 180 minutes

2. **`aflpp_build_cmplog`** ([Lines 130-218](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L130-L218))
   - Builds with CMPLOG instrumentation
   - Environment: `AFL_LLVM_CMPLOG=1`
   - Used for comparison-guided fuzzing

3. **`aflpp_fuzz`** ([Lines 221-466](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L221-L466))
   - Secondary fuzzer instances (`-S` mode)
   - Max concurrent jobs: 3000
   - Replicable: true (scales up to 20 replicas/minute)
   - CPU: 1 core, Memory: 2Gi per job

4. **`aflpp_fuzz_main_replicant`** ([Lines 467-665](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L467-L665))
   - Primary fuzzer instance (`-M` mode) per harness
   - Coordinates corpus synchronization
   - One per harness (non-replicable)

5. **`aflpp_cross_node_sync`** ([Lines 750-847](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L750-L847))
   - Runs every 2 minutes
   - SSH-based rsync between nodes
   - Crash injection to all instances

6. **`aflpp_fuzz_merge`** ([Lines 849-982](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L849-L982))
   - Continuous corpus collection
   - Outputs to PDT repositories
   - Runs every 5 minutes

## Docker Image

**Dockerfile**: [`Dockerfile`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/Dockerfile)

**Base Image** ([Line 10](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/Dockerfile#L10)):
```dockerfile
FROM gcr.io/oss-fuzz-base/base-clang
```

**AFL++ Installation** ([Lines 32-44](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/Dockerfile#L32-L44)):
- Clones from GitHub: `https://github.com/AFLplusplus/AFLplusplus.git`
- Custom modification: Added debug prints to `sync_fuzzers()` ([Lines 33-34](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/Dockerfile#L33-L34))
- Compiles with LLVM 15, static linking
- Installed to `/AFLplusplus`

**Additional Tools** ([Lines 56-57](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/Dockerfile#L56-L57)):
- libfreedom for dependency management

## Custom Fuzzer Wrapper

**Script**: [`shellphish_aflpp_fuzz.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/shellphish_aflpp_fuzz.sh)

### Key Features

**Instance Naming** ([Lines 23-30](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/shellphish_aflpp_fuzz.sh#L23-L30)):
```bash
# MD5 hash for fuzzer names > 32 chars (AFL++ limit)
if [ ${#FUZZER_NAME} -gt 32 ]; then
    FUZZER_NAME_MD5=$(echo -n "$FUZZER_NAME" | md5sum | cut -d' ' -f1)
    FUZZER_NAME="${FUZZER_NAME:0:16}_${FUZZER_NAME_MD5:0:15}"
fi
```

**Corpus Setup** ([Lines 32-35](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/shellphish_aflpp_fuzz.sh#L32-L35)):
```bash
# Shared sync directory
SYNC_DIR="/shared/fuzzer_sync/${PROJECT_NAME}-${HARNESS_NAME}"
mkdir -p "$SYNC_DIR"

# Initial corpus
INITIAL_CORPUS="/work/initial_corpus"
```

**Continuous Fuzzing Loop** ([Lines 48-87](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/shellphish_aflpp_fuzz.sh#L48-L87)):
```bash
while true; do
    # Run AFL++ fuzzer
    AFL_SKIP_CRASHES=1 afl-fuzz \
        -i "$INITIAL_CORPUS" \
        -o "$SYNC_DIR" \
        -S "$FUZZER_NAME" \  # Secondary mode (-S)
        -x dict.txt \        # Dictionary
        -g 1000 \            # Grammar
        -- /out/"$HARNESS"

    # Auto-recovery on crash
    if [ $? -ne 0 ]; then
        echo "Fuzzer crashed, restarting..."

        # Re-seed from non-crashing inputs
        if [ -d "$SYNC_DIR/$FUZZER_NAME/queue" ]; then
            rm -rf "$INITIAL_CORPUS"
            cp -r "$SYNC_DIR/$FUZZER_NAME/queue" "$INITIAL_CORPUS"
        fi

        sleep 5
        continue
    fi

    break
done
```

### Grammar Support

**Nautilus Integration** ([pipeline.yaml Lines 122-124](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L122-L124)):
```yaml
rsync -av /shellphish/libs/nautilus/grammars/reference/ \
    ${project_build_artifact_out}/grammars/
```

**AFL++ Flags** ([shellphish_aflpp_fuzz.sh Line 60](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/shellphish_aflpp_fuzz.sh#L60)):
- `-g 1000`: Grammar mutation weight
- Nautilus mutator enabled automatically when grammar present

## Cross-Node Synchronization

**Script**: [`main_node_rsync_shit.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/main_node_rsync_shit.sh)

### Sync Strategy

**Three-Way Sync** ([Lines 115-172](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/main_node_rsync_shit.sh#L115-L172)):

1. **Outbound Sync** ([Lines 121-131](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/main_node_rsync_shit.sh#L121-L131)):
   ```bash
   # Push local corpus to remote nodes
   rsync -avz --timeout=30 \
       "$SYNC_DIR/" \
       "root@$REMOTE_NODE:$SYNC_DIR/"
   ```

2. **Inbound Sync** ([Lines 133-143](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/main_node_rsync_shit.sh#L133-L143)):
   ```bash
   # Pull remote corpus to local
   rsync -avz --timeout=30 \
       "root@$REMOTE_NODE:$SYNC_DIR/" \
       "$SYNC_DIR/"
   ```

3. **Backsync** ([Lines 145-155](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/main_node_rsync_shit.sh#L145-L155)):
   ```bash
   # Push back any new findings
   rsync -avz --timeout=30 \
       "$SYNC_DIR/" \
       "root@$REMOTE_NODE:$SYNC_DIR/"
   ```

### Stale Fuzzer Eviction

**Algorithm** ([Lines 50-70](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/main_node_rsync_shit.sh#L50-L70)):
```bash
STALE_THRESHOLD=300  # 5 minutes

for fuzzer_dir in "$SYNC_DIR"/*/; do
    fuzzer_stats="$fuzzer_dir/fuzzer_stats"

    if [ -f "$fuzzer_stats" ]; then
        last_update=$(stat -c %Y "$fuzzer_stats")
        current_time=$(date +%s)
        age=$((current_time - last_update))

        if [ $age -gt $STALE_THRESHOLD ]; then
            echo "Evicting stale fuzzer: $fuzzer_dir"
            rm -rf "$fuzzer_dir"
        fi
    fi
done
```

### Crash Injection

**Implementation** ([Lines 197-201](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/main_node_rsync_shit.sh#L197-L201)):
```bash
# Copy crashes to all secondary fuzzers
for crash in "$SYNC_DIR"/main/crashes/*; do
    for secondary in "$SYNC_DIR"/secondary_*/queue/; do
        cp "$crash" "$secondary"
    done
done
```

### Inter-Harness Sharing

**Feature** ([Lines 203-207](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/main_node_rsync_shit.sh#L203-L207)):
- Seeds from one harness shared with related harnesses
- Uses project name matching
- Helps cross-pollinate corpus across targets

## CMPLOG Mode

**Purpose**: Break complex comparisons (e.g., `if (strcmp(input, "SECRET") == 0)`)

**Build Configuration** ([pipeline.yaml Lines 130-218](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L130-L218)):
```yaml
environment:
  AFL_LLVM_CMPLOG: "1"
```

**Usage in Fuzzing**:
- Main replicant uses CMPLOG binary
- Flag: `-c /out/harness_cmplog`
- Slows down fuzzing but improves finding rate for comparison-heavy code

## Corpus Management

### Initial Corpus

**Sources** ([pipeline.yaml Lines 370-380](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L370-L380)):
- Corpus-Guy generated seeds
- Grammar-Guy structured inputs
- Known crashes from previous runs
- `/work/initial_corpus` directory

### Continuous Minimization

**AFL++ Built-in**:
- Automatic corpus minimization during fuzzing
- Keeps smallest inputs per coverage path
- Prunes redundant corpus entries

**Merge Task** ([pipeline.yaml Lines 849-982](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L849-L982)):
- Runs every 5 minutes
- Collects corpus from all fuzzers
- Validates with `afl-showmap`
- Outputs to PDT repositories

### Crash Corpus

**Storage** ([pipeline.yaml Lines 403-430](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L403-L430)):
- `crashing_harness_inputs` repository
- Includes ASAN reports
- Coverage metadata per crash

**Benign Corpus** ([Lines 432-459](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L432-L459)):
- `benign_harness_inputs` repository
- Non-crashing interesting inputs
- Used for regression testing

## Dictionary Support

### Auto-Generated Dictionaries

**LLVM Instrumentation** ([compile script](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflplusplus/compile#L30)):
```bash
export AFL_LLVM_DICT2FILE=/out/afl++.dict
```

Automatically extracts:
- String literals
- Integer constants
- Magic numbers
- Comparison values

### Manual Dictionaries

**Corpus-Guy Integration**:
- CodeQL extracts magic values
- Saved as `dict.txt` in corpus
- AFL++ flag: `-x dict.txt`

## Resource Configuration

### Job Quotas

**Secondary Fuzzers** ([pipeline.yaml Lines 235-240](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L235-L240)):
```yaml
job_quota:
  cpu: 1
  mem: "2Gi"
max_concurrent_jobs: 3000
replicable: true
replicate_up_to: 20  # per minute
```

**Main Replicant** ([Lines 482-486](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L482-L486)):
```yaml
job_quota:
  cpu: 1
  mem: "2Gi"
max_concurrent_jobs: 1000
replicable: false  # One per harness
```

### Spot Instance Support

**Configuration** ([Lines 241-246](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L241-L246)):
```yaml
spot_ok: true
node_affinity:
  "support.shellphish.net/spot": "true"
```

Uses cheaper spot instances for cost efficiency.

## Integration with Other Components

### Upstream

**Grammar-Guy**:
- Provides Nautilus grammars
- Coverage-guided grammar refinement

**Corpus-Guy**:
- Generates initial seeds
- Provides dictionaries

**Static Analysis**:
- Locations of interest for targeted fuzzing
- CWE findings for prioritization

### Downstream

**Coverage-Guy**:
- Monitors coverage growth
- Tracks fuzzing effectiveness

**Crash Analysis**:
- Crash-Tracer parses ASAN reports
- Crash Exploration finds variants

**AFLRun**:
- Uses AFL++ crashes for targeted fuzzing
- Shares corpus via same sync mechanism

## Performance Characteristics

### Execution Speed

- **Standard mode**: 100-10,000 execs/sec depending on target
- **CMPLOG mode**: 10-50% slower but better finding rate
- **Grammar mode**: 20-40% slower but finds structured bugs

### Coverage Growth

- **Initial phase** (0-24 hours): Rapid growth with grammar mutations
- **Plateau phase** (1-7 days): Slower growth, cross-node sync helps
- **Long-tail phase** (7+ days): Minimal new coverage, focus shifts

### Bug Discovery

- **Shallow bugs**: Found within hours (buffer overflows, null pointers)
- **Deep bugs**: Days to weeks (complex logic errors)
- **Grammar-assisted**: 2-5x faster for structured input bugs

## Error Handling

**Fuzzer Crashes** ([shellphish_aflpp_fuzz.sh Lines 70-85](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/aflplusplus_modifications/shellphish_aflpp_fuzz.sh#L70-L85)):
- Auto-restart with corpus recovery
- Re-seed from last valid queue
- Logs error and continues

**Sync Failures**:
- Timeout handling (30 seconds per rsync)
- Skip failed nodes and continue
- Retry on next sync cycle

**Build Failures**:
- Fallback to non-instrumented builds if AFL++ instrumentation fails
- Log warnings but continue pipeline

## Related Components

- **[AFLRun](./aflrun.md)**: Targeted variant of AFL++
- **[Grammar-Guy](../grammar/grammar-guy.md)**: Grammar generation and refinement
- **[Corpus-Guy](../grammar/corpus-guy.md)**: Seed generation and management
- **[Coverage-Guy](../coverage/coverage-guy.md)**: Coverage monitoring
