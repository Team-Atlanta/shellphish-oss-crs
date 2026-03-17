# Crash Exploration

Crash Exploration uses AFL++ to mutate representative crashing inputs and discover variants in the crash neighborhood. It runs a short fuzzing campaign (4 hours) focused on finding related crashes rather than maximizing coverage.

## Purpose

- Generate crash variants from representative crashes
- Explore crash neighborhoods
- Find related but distinct crashes
- Provide diverse crashing inputs for invariant mining and POV generation

## CRS-Specific Features

**Configuration** ([pipeline.yaml Lines 101-135](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash_exploration/pipeline.yaml#L101-L135)):

```bash
# AFL++ configuration for crash exploration
export ARTIPHISHELL_AFL_TIMEOUT=300                    # 5-minute total timeout
export ARTIPHISHELL_AFL_EXTRA_ARGS="-C"                # Crash mode
export ARTIPHISHELL_DO_NOT_CREATE_INPUT=1              # Don't generate initial corpus
export FORCED_CREATE_INITIAL_INPUT=1                   # Use provided crash as seed
export FORCED_USE_CUSTOM_MUTATOR=1                     # Enable custom mutator
export FORCED_USE_AFLPP_DICT=0                         # Disable dictionary
export FORCED_FUZZER_TIMEOUT=4                         # 4-hour fuzzing campaign
export FORCED_DO_CMPLOG=1                              # Enable cmplog for comparison coverage
export FORCED_USE_CORPUSGUY_DICT=0                     # Disable corpus-guy dictionary
export CRASH_EXPLORATION_MODE=true                     # Enable crash exploration mode
```

**Corpus Initialization** ([Lines 179-189](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash_exploration/pipeline.yaml#L179-L189)):
```bash
# Create corpus with 3 copies of crashing input
mkdir -p $CORPUS_DIR
rsync -ra {{dedup_pov_report_representative_crashing_input_path | shquote}} $CORPUS_DIR
cp {{dedup_pov_report_representative_crashing_input_path | shquote}} $CORPUS_DIR/crash_1
cp {{dedup_pov_report_representative_crashing_input_path | shquote}} $CORPUS_DIR/crash_2
```

**Crash Collection** ([Lines 219-227](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash_exploration/pipeline.yaml#L219-L227)):
```bash
# Copy all discovered crashes to output
rsync -av "$ARTIPHISHELL_FUZZER_SYNC_DIR/$ARTIPHISHELL_FUZZER_INSTANCE_NAME/crashes/" \
    "{{ crashes | shquote }}"
```

## Workflow

### 1. Input
- **Representative crashing input**: Selected by deduplication
- **AFL++ build artifacts**: Instrumented binaries
- **Harness metadata**: Target harness information

### 2. Fuzzing Campaign
- Start AFL++ in crash exploration mode
- Seed with representative crash (3 copies)
- Run for 4 hours
- Use custom mutator for better mutations
- Enable cmplog for comparison coverage

### 3. Output
- **Directory of crashes**: All variants discovered
- **Metadata YAML**: Harness info, success status

## Integration

**Pipeline Configuration** ([Lines 22-89](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash_exploration/pipeline.yaml#L22-L89)):
```yaml
tasks:
  crash_exploration:
    long_running: false
    priority_function: "harness_queue"  # Prioritize by harness backlog
    priority: 2
    failure_ok: true

    job_quota:
      cpu: 1
      mem: "6Gi"

    max_concurrent_jobs: 16

    links:
      crashing_input_metadata:
        repo: dedup_pov_report_representative_metadatas
        kind: InputMetadata

      dedup_pov_report_representative_crashing_input_path:
        repo: dedup_pov_report_representative_crashing_inputs
        kind: InputFilepath

      aflpp_build_artifacts_dir:
        repo: aflpp_build_artifacts
        kind: InputFilepath

      crashes:
        repo: crashing_harness_inputs_exploration
        kind: OutputFilepath
```

## Key Differences from Regular Fuzzing

| Feature | Regular AFL++ | Crash Exploration |
|---------|---------------|-------------------|
| **Goal** | Maximize coverage | Find crash variants |
| **Corpus** | Diverse seeds | Single crash (3 copies) |
| **Duration** | 24+ hours | 4 hours |
| **Dictionary** | Corpus-guy + AFL++ | None |
| **Custom Mutator** | Optional | Forced on |
| **Cmplog** | Optional | Forced on |
| **Timeout** | Longer | Shorter (5 min) |

## Related Components

- **[AFL++](../fuzzing/aflplusplus.md)**: Underlying fuzzer
- **[Crash-Tracer](./crash-tracer.md)**: Parses discovered crashes
- **[Invariant-Guy](./invariant-guy.md)**: Uses crash variants for invariant mining
