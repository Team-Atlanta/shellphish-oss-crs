# DyVA (Dynamic Vulnerability Analyzer)

DyVA performs **dynamic root cause analysis** for crashes by replaying them with instrumentation to identify the precise vulnerability location and extract variable states. It builds on POI reports to focus tracing on relevant code regions.

## Purpose

- Root cause localization for crashes
- Dynamic variable value analysis
- Precise vulnerability location identification
- Local variable state extraction at crash sites
- Support patch generation with runtime context

## CRS-Specific Usage

**Integration** ([pipeline.yaml Lines 25-112](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/dyva/pipeline.yaml#L25-L112)):

```yaml
tasks:
  dyva_agent:
    failure_ok: true
    priority_function: "harness_queue"  # Prioritize by backlog

    links:
      patch_request_meta:
        repo: patch_requests_meta
        kind: InputMetadata

      crashing_input:
        repo: dedup_pov_report_representative_crashing_inputs
        kind: InputFilepath

      point_of_interest:
        repo: points_of_interest
        kind: InputFilepath

      dyva_build_artifact:
        repo: dyva_build_artifacts  # Special instrumented build
        kind: InputFilepath

      dyva_report:
        repo: dyva_reports
        kind: OutputFilepath
```

## Workflow

### 1. Build with DyVA Instrumentation ([Lines 114-176](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/dyva/pipeline.yaml#L114-L176))

**Task**: `dyva_build`

```yaml
dyva_build:
  priority: 2
  require_success: true
  timeout:
    minutes: 180  # Long timeout for instrumented builds

  job_quota:
    cpu: 0.5
    mem: "500Mi"

  template: |
    export OSS_FUZZ_PROJECT_DIR={{ project_oss_fuzz_repo | shquote }}/projects/{{ crs_task.project_name | shquote }}/
    export BUILD_CONFIGURATION_ARCHITECTURE={{ build_configuration.architecture }}
    export BUILD_CONFIGURATION_SANITIZER={{ build_configuration.sanitizer }}
    export DYVA_BUILD_ARTIFACT={{ dyva_build_artifact | shquote }}

    /app/run_scripts/run-dyva-build.sh
```

**Output**: Instrumented binary with dynamic tracing hooks

### 2. Run DyVA Agent ([Lines 99-112](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/dyva/pipeline.yaml#L99-L112))

```yaml
template: |
  export POI_REPORT={{ point_of_interest | shquote }}
  export DYVA_BUILD_ARTIFACT={{ dyva_build_artifact | shquote }}
  export CRASHING_INPUT={{ crashing_input | shquote }}
  export OSS_FUZZ_PROJECT={{ oss_fuzz_project | shquote }}
  export PROJECT_METADATA={{ project_metadata | shquote }}
  export LOCAL_VARIABLE_REPORT={{ dyva_report | shquote }}

  /app/run_scripts/run-dyva-agent.sh
```

**Process**:
1. Load POI report (from POI-Guy or Kumu-Shi)
2. Replay crashing input with instrumentation
3. Trace variable values at POI locations
4. Identify root cause based on variable states
5. Generate DyVA report with local variable analysis

## DyVA Report Structure

```yaml
# Example DyVA report
project_id: "proj-123"
crash_report_id: "crash-789"
poi_report_id: "poi-456"

root_cause:
  location: "/src/foo.c:42"
  function: "vulnerable_function"
  type: "buffer_overflow"
  description: "Stack buffer overflow due to unbounded memcpy"

local_variables:
  - name: "buf_len"
    value: 1024
    type: "size_t"
    expected_range: "0-16"
    violation: true

  - name: "stack_buf"
    address: "0x7fff12345000"
    size: 16
    allocation_site: "/src/foo.c:40"

  - name: "input_buf"
    address: "0x55d9c0a2b000"
    size: 1024
    source: "fuzzer_input"

taint_analysis:
  tainted_variables: ["buf_len", "input_buf"]
  input_bytes_influence: [0, 1, 2, 3]  # Bytes 0-3 control buf_len
```

## Integration with POI Reports

**Input**: POI report identifies Points of Interest

**Example POI Report**:
```yaml
points_of_interest:
  - location: "/src/foo.c:42"
    function: "vulnerable_function"
    reason: "crash_site"
    variables: ["buf_len", "stack_buf", "input_buf"]
```

**DyVA Action**:
1. Insert dynamic probes at `/src/foo.c:42`
2. Trace variables: `buf_len`, `stack_buf`, `input_buf`
3. Replay crash and capture variable states
4. Analyze which variable violations led to crash

## Performance Characteristics

- **Priority**: `harness_queue` - prioritizes based on backlog
- **Resources**: Variable (dynamic tracing overhead)
- **Timeout**: 180 minutes for instrumented builds
- **Failure handling**: `failure_ok: true` - non-blocking

## Related Components

- **[POI-Guy](../pov-generation/poi-guy.md)**: Generates POI reports for DyVA
- **[Kumu-Shi-Runner](../crash-analysis/kumu-shi-runner.md)**: Alternative POI generation
- **[Invariant-Guy](../crash-analysis/invariant-guy.md)**: Complementary invariant mining
- **[Crash-Tracer](../crash-analysis/crash-tracer.md)**: Provides crash inputs
- **[Patch Generation](../../patch-generation/)**: Uses DyVA reports for context-aware patching
