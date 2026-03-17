# Invariant-Guy

Invariant-Guy mines program invariants at crash sites by dynamically tracing variable values during execution. It compares crashing vs benign runs to infer predicates that hold for benign inputs but are violated by crashes. Supports C/C++ (perf probes), Java (btrace), and Linux kernel (kernel probes).

## Purpose

- Mine invariants at Points of Interest (POI)
- Compare crashing vs benign execution traces
- Infer unary and binary predicates
- Support C/C++, Java, and kernel targets
- Provide invariants for patch validation and POV generation

## Architecture

Invariant-Guy uses **language-specific tracing** (Carrot framework):

- **C/C++**: `perf probe` for userspace dynamic tracing
- **Java**: `btrace` for JVM instrumentation
- **Linux kernel**: `perf kprobe` for kernel tracing

## Implementation

**Main Components**:
- `src/invguy.py`: Main entry point and dispatcher
- `src/invguy-build.py`: Build target with instrumentation
- `src/c_guy/`: C/C++ tracing (perf probes)
- `src/java_guy/`: Java tracing (btrace)
- `src/kernel_guy/`: Kernel tracing (kprobes)
- `src/carrot/`: Invariant mining algorithms

## Workflow

### 1. Build with Instrumentation ([pipeline.yaml Lines 59-118](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/invariant-guy/pipeline.yaml#L59-L118))

```yaml
invariant_build:
  job_quota:
    max: 0.45  # Resource-intensive

  # Build target with perf/btrace instrumentation
  # Output: targets_built_with_instrumentation
```

**Process**:
- Copy target source directory
- Build with debug symbols (-g)
- Preserve symbol table for probe insertion
- Output: Instrumented binary + metadata

### 2. Invariant Mining ([Lines 120-211](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/invariant-guy/pipeline.yaml#L120-L211))

**Three separate tasks by language**:

#### C/C++ ([Lines 120-211](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/invariant-guy/pipeline.yaml#L120-L211))
```yaml
invariant_find_c:
  job_quota:
    cpu: "2"
    mem: "4Gi"

  links:
    poi_report: poi_reports                                   # Points of Interest
    representative_crashing_harness_input:                    # Crash to analyze
    similar_harness_inputs_dir: similar_harness_inputs_dirs   # Benign inputs
    non_kernel_c_target_built_with_instrumentation:           # Instrumented binary

  template: |
    export TARGET_BUILT_WITH_INSTRUMENTATION=$TMPDIR/cp-folder
    export REPRESENTATIVE_CRASHING_HARNESS_INPUT={{ representative_crashing_harness_input | shquote }}
    export SIMILAR_HARNESS_INPUT_DIR={{ similar_harness_inputs_dir | shquote }}
    export POI_REPORT={{ poi_report | shquote }}
    export OUT_REPORT_AT={{ invariant_report | shquote }}

    /src/run-find.sh
```

#### Java ([Lines 212-302](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/invariant-guy/pipeline.yaml#L212-L302))
```yaml
invariant_find_java:
  # Similar structure, uses btrace instead of perf
```

#### Linux Kernel ([Lines 304-393](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/invariant-guy/pipeline.yaml#L304-L393))
```yaml
invariant_find_kernel:
  job_quota:
    cpu: "8"      # More resources for kernel tracing
    mem: "16Gi"
  # Uses kprobes in kernel context
```

## Carrot Invariant Framework

### Invariant Types

**Unary Invariants** (`src/carrot/invariants/unary/`):
- Numerical: `x == 0`, `x > 0`, `x < 0`, `x in range`
- Boolean: `x == true`, `x == false`
- String: `x == ""`, `x != null`, `x.length() > 0`

**Binary Invariants** (`src/carrot/invariants/binary/`):
- Numerical: `x < y`, `x == y`, `x + y == z`
- Boolean: `x == y`, `x != y`
- String: `x.equals(y)`, `x.startsWith(y)`, `x.contains(y)`

### Mining Algorithm

1. **Trace Collection**:
   - Insert probes at POI (from POI reports)
   - Execute representative crash
   - Execute ~10 similar benign inputs
   - Collect variable values at each probe point

2. **Candidate Generation**:
   - Generate all applicable invariant templates
   - For each variable: test unary invariants
   - For each variable pair: test binary invariants

3. **Filtering**:
   - **Holds for benign**: Invariant true for all benign runs
   - **Violated by crash**: Invariant false for crashing run
   - Output: Invariants likely related to vulnerability

## Example Invariant Report

```yaml
project_id: "proj-123"
harness_info_id: "harness-456"
crash_report_id: "crash-789"

invariants:
  - poi: "/src/foo.c:42"
    function: "vulnerable_function"
    variable: "buf_len"
    type: "unary_numerical"
    predicate: "buf_len > 0"
    benign_holds: true
    crash_violates: true
    confidence: 0.95

  - poi: "/src/foo.c:42"
    function: "vulnerable_function"
    variables: ["buf_len", "buf_capacity"]
    type: "binary_numerical"
    predicate: "buf_len <= buf_capacity"
    benign_holds: true
    crash_violates: true
    confidence: 0.98
```

## Integration with POI Reports

**POI Report** (from POI-Guy):
```yaml
project_id: "proj-123"
points_of_interest:
  - location: "/src/foo.c:42"
    function: "vulnerable_function"
    reason: "crash_site"
    variables: ["buf_len", "buf_capacity", "buf"]
```

**Invariant-Guy**:
1. Read POI report
2. Insert probes at POI locations
3. Trace specified variables
4. Mine invariants for those variables

## Performance Characteristics

- **C/C++**: ~2-5 minutes per crash (2 CPU, 4Gi RAM)
- **Java**: ~5-10 minutes per crash (1 CPU, 5Gi RAM)
- **Kernel**: ~10-30 minutes per crash (8 CPU, 16Gi RAM)

## Related Components

- **[POI-Guy](../pov-generation/poi-guy.md)**: Identifies Points of Interest for tracing
- **[Crash-Tracer](./crash-tracer.md)**: Provides crash reports
- **[Crash Exploration](./crash-exploration.md)**: Provides crash variants
- **[POV-Guy](../pov-generation/pov-guy.md)**: Uses invariants for exploit generation
