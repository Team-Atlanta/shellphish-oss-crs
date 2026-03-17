# AFLRun

AFLRun is an **in-house targeted fuzzing tool** based on [Mem2019/AFLRun](https://github.com/Mem2019/AFLRun.git) that focuses fuzzing effort on specific basic blocks of interest identified by static analysis. Unlike AFL++ which aims for broad coverage, AFLRun instruments only targeted locations to efficiently reach potentially vulnerable code.

## Purpose

- Directed fuzzing toward static analysis findings (SARIF reports)
- Selective basic-block instrumentation for efficiency
- Focus fuzzing on locations flagged by CodeChecker/CodeQL/Semgrep
- Complement broad AFL++ coverage with targeted exploration

## Architecture

### Pipeline Configuration

**File**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflrun/pipeline.yaml)

**Tasks**:
1. **`aflrun_build`** ([Lines 22-125](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflrun/pipeline.yaml#L22-L125)) - Build with BB targeting
2. **`aflrun_fuzz`** ([Lines 126-296](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflrun/pipeline.yaml#L126-L296)) - Run targeted fuzzing

**Resource Limits**:
- CPU: 1 core, Memory: 2Gi
- Max concurrent jobs: 2 (much lower than AFL++'s 3000)
- Priority: 10

## Implementation

### Source Location

**Base**: [`libs/crs-utils/.../instrumentation/aflrun/`](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun)

**Key Files**:
- **Dockerfile.prebuild**: Clones AFLRun from GitHub ([Lines 26-29](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun/Dockerfile.prebuild#L26-L29))
- **precompile_aflrun**: Compiles AFLRun with LLVM 15 ([Lines 1-15](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun/precompile_aflrun#L1-L15))
- **compile_aflrun**: Build-time instrumentation setup ([Lines 1-49](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun/compile_aflrun#L1-L49))
- **run_fuzzer**: Runtime wrapper ([Lines 1-158](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun/run_fuzzer#L1-L158))

### Build Process

**Step 1: Precompile AFLRun** ([precompile_aflrun](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun/precompile_aflrun)):

```bash
# Clone AFLRun from GitHub
git clone https://github.com/Mem2019/AFLRun.git /AFLRun
cd /AFLRun
git submodule init
git submodule update  # robin-hood-hashing library

# Compile with LLVM 15
CC=clang-15 CXX=clang++-15 make -j$(nproc)
```

**Step 2: Target Selection** ([compile_aflrun Lines 16-17](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun/compile_aflrun#L16-L17)):

```bash
# Decode base64-encoded basic block targets
echo "$AFLRUN_BUILD_BB_FILE" | base64 -d > /tmp/bb_targets.txt

# Set environment for instrumentation
export AFLRUN_BB_TARGETS=/tmp/bb_targets.txt
```

**BB Targets Format** ([pipeline.yaml Lines 58-61](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflrun/pipeline.yaml#L58-L61)):
```bash
# From locs_of_interest repository (SARIF-derived)
# Format: /path/to/file.c:line_number
AFLRUN_BUILD_BB_FILE={{ locs_of_interest | base64 }}
```

**Step 3: Instrumentation** ([compile_aflrun Lines 27-35](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun/compile_aflrun#L27-L35)):

```bash
# Copy precompiled AFLRun binaries
cp /AFLRun/afl-fuzz /out/
cp /AFLRun/afl-showmap /out/

# Enable trace-PC instrumentation (selective)
export AFL_LLVM_USE_TRACE_PC=1

# Standard compile with selective instrumentation
/compile "$@"
```

### How It Differs from AFL++

**1. Selective Instrumentation**:
- AFL++: Instruments all edges/blocks
- AFLRun: Only instruments blocks in `AFLRUN_BB_TARGETS`
- **Algorithm**: robin-hood hashing for O(1) BB lookup during instrumentation

**2. Targeted Coverage**:
- AFL++: Maximizes overall coverage
- AFLRun: Maximizes coverage of *specific* locations
- Feedback rewards reaching target blocks

**3. Linker Wrapper** ([Dockerfile.builder Lines 36-43](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun/Dockerfile.builder#L36-L43)):

```bash
# Custom linker wrapper intercepts link step
cp /anti-wrap-ld.sh /usr/bin/ld
chmod +x /usr/bin/ld

# Ensures AFLRun instrumentation gets linked
export AFL_PATH=/AFLRun
```

### Runtime Execution

**Fuzzer Wrapper**: [`run_fuzzer`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun/run_fuzzer)

**Detection Logic** ([Lines 125-158](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflrun/run_fuzzer#L125-L158)):

```bash
# Detect AFL mode based on harness binary
if strings "/out/$TARGET_NAME" | grep -q "__afl_area_ptr"; then
    echo "Detected AFL instrumentation"

    # Use AFLRun fuzzer
    FUZZER="/out/afl-fuzz"

    # AFL-specific flags
    FUZZER_ARGS="-i $CORPUS_DIR -o $OUTPUT_DIR -t 1000+"

    # Optionally use dictionary
    if [ -f "$DICT_FILE" ]; then
        FUZZER_ARGS="$FUZZER_ARGS -x $DICT_FILE"
    fi

    # Run AFLRun
    $FUZZER $FUZZER_ARGS -- "/out/$TARGET_NAME"
else
    # Fallback to libFuzzer mode
    echo "No AFL instrumentation, using libFuzzer mode"
    "/out/$TARGET_NAME" "$CORPUS_DIR" -dict="$DICT_FILE"
fi
```

## Integration with Static Analysis

### Input: Locations of Interest

**Source**: [`locs_of_interest`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflrun/pipeline.yaml#L58-L61) repository from:
- **CodeChecker**: HIGH severity findings ([codechecker/extract.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/scripts/extract.py#L6-L9))
- **Semgrep**: Vulnerability pattern matches
- **CodeQL**: CWE query results

**Format**:
```
/src/project/file.c:42
/src/project/file.c:105
/src/project/other.cpp:73
```

### Workflow

```
Static Analysis (CodeChecker/CodeQL/Semgrep)
           ↓
    Identifies suspicious locations
           ↓
    locs_of_interest repository
           ↓
    Base64 encode → AFLRUN_BUILD_BB_FILE
           ↓
    AFLRun build: selective instrumentation
           ↓
    AFLRun fuzz: directed toward targets
           ↓
    Crashes → standard crash corpus
```

## Corpus Synchronization

**Shared Sync** ([pipeline.yaml Lines 228-232](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflrun/pipeline.yaml#L228-L232)):

```yaml
# Same sync mechanism as AFL++
SYNC_DIR: /shared/fuzzer_sync/${PROJECT_NAME}-${HARNESS_NAME}
```

- AFLRun shares corpus with AFL++ instances
- Cross-pollination: AFL++ broad coverage → AFLRun targets
- AFLRun findings → injected back to AFL++ queue

## Key Algorithms

### robin-hood Hashing

**Purpose**: Fast O(1) lookup for target blocks during instrumentation

**Implementation** (AFLRun upstream):
- Hash table with open addressing
- Keys: `(filename, line_number)` pairs
- Values: Boolean (is_target)
- Probing: robin-hood strategy for better cache locality

### Selective PC Guard

**LLVM Pass**:
1. For each basic block in IR:
   ```cpp
   if (aflrun_bb_targets.contains(bb.filename, bb.line)) {
       insert_pc_guard(bb);  // Instrument this block
   } else {
       // Skip instrumentation
   }
   ```

2. PC guard callback:
   ```c
   void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
       // Standard AFL++ edge coverage
       __afl_area_ptr[*guard]++;
   }
   ```

## Performance Characteristics

### Instrumentation Overhead

- **AFL++**: 2-5x slowdown (all blocks instrumented)
- **AFLRun**: 1.5-3x slowdown (selective instrumentation)
- **Benefit**: Faster execution allows more iterations

### Effectiveness

**Best Use Cases**:
- Deep functions with complex paths
- Functions flagged by static analysis
- Low-level parsing code with known issues

**Less Effective**:
- Shallow functions (reached quickly anyway)
- Functions not in target list (no instrumentation)

### Throughput

- **Execs/sec**: 20-50% faster than AFL++ on same target
- **Coverage growth**: Focused on target regions only
- **Time to target**: 2-10x faster reaching specific locations

## Resource Configuration

**Job Limits** ([pipeline.yaml Lines 140-145](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflrun/pipeline.yaml#L140-L145)):

```yaml
job_quota:
  cpu: 1
  mem: "2Gi"
max_concurrent_jobs: 2  # Much lower than AFL++
replicable: false
```

**Rationale**: Targeted fuzzing requires fewer instances; focus over scale

## Output Formats

### Crash Corpus

**Same as AFL++** ([pipeline.yaml Lines 235-265](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflrun/pipeline.yaml#L235-L265)):
- `crashing_harness_inputs`: Crashes with ASAN reports
- `benign_harness_inputs`: Non-crashing interesting inputs
- Coverage metadata per input

### Sync Directories

```
/shared/fuzzer_sync/${PROJECT}-${HARNESS}/
├── aflrun_instance_1/
│   ├── queue/          # Interesting inputs
│   ├── crashes/        # Crashing inputs
│   └── fuzzer_stats    # Runtime stats
└── ... (AFL++ instances)
```

## Integration Points

### Upstream

**CodeChecker** ([codechecker/pipeline.yaml Lines 104-107](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/pipeline.yaml#L104-L107)):
- Extracts `locs_of_interest` from HIGH severity findings
- Maps findings to file:line format

**Static Analysis**:
- SARIF reports → locations
- CWE findings → prioritization

### Downstream

**Crash Analysis**:
- Standard crash processing pipeline
- Same as AFL++ crashes

**AFL++**:
- Corpus sharing via sync directories
- AFLRun findings enrich AFL++ corpus

## Use Cases

### Scenario 1: SARIF-Guided Fuzzing

**Problem**: CodeQL finds potential buffer overflow at `parser.c:142`

**Solution**:
1. CodeQL adds `parser.c:142` to `locs_of_interest`
2. AFLRun builds with selective instrumentation
3. Fuzzer rewards reaching line 142
4. Finds exploitable crash within hours

### Scenario 2: Patch Validation

**Problem**: Patch applied to fix bug at `auth.c:89`

**Solution**:
1. Add `auth.c:89` to targets
2. AFLRun fuzzes around the patch
3. Validates fix or finds regression

### Scenario 3: Deep Path Fuzzing

**Problem**: Complex function deep in call stack rarely reached

**Solution**:
1. Static analysis identifies deep function entry
2. AFLRun targets function entry block
3. Reaches deep code 10x faster than AFL++

## Error Handling

**Build Failures**:
- Falls back to AFL++ if AFLRun instrumentation fails
- Logs warning and continues

**Empty Target List**:
- If `locs_of_interest` is empty, skips AFLRun entirely
- AFLRun task doesn't run

**Sync Failures**:
- Graceful degradation: continues fuzzing without sync
- Retry on next sync cycle

## Related Components

- **[AFL++](./aflplusplus.md)**: Parent fuzzer, shares corpus
- **[CodeChecker](../static-analysis/codechecker.md)**: Provides locations of interest
- **[Coverage-Guy](../coverage/coverage-guy.md)**: Monitors target coverage
