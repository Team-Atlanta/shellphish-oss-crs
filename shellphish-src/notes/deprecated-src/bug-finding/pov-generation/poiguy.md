# POIGuy

POIGuy extracts **Points of Interest (POI)** from crash reports by parsing ASAN/MSAN stack traces and identifying relevant source locations for deeper analysis. It generates structured POI reports consumed by Invariant-Guy, DyVA, and other analysis components.

## Purpose

- Parse sanitizer stack traces
- Extract crash site location
- Identify related functions in call stack
- Generate structured POI reports
- Support fuzzing and static analysis sources

## POI Report Schema

**JSON Schema** ([README.md Lines 6-145](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/poiguy/README.md#L6-L145)):

```json
{
  "project_id": "proj-123",
  "scanner": "aflplusplus",
  "detection_strategy": "fuzzing",
  "harness_id": "harness-456",
  "crash_reason": "heap-buffer-overflow",

  "pois": [
    {
      "reason": "crash_site",
      "source_location": {
        "relative_file_path": "src/foo.c",
        "function_signature": "int vulnerable_function(char *buf, size_t len)",
        "line_text": "memcpy(stack_buf, buf, len);",
        "line_number": 42,
        "symbol_offset": 1234,
        "symbol_size": 256,
        "key_index": "src/foo.c:40:5::int vulnerable_function(char *buf, size_t len)"
      }
    }
  ],

  "stack_traces": [
    {
      "reason": "main",
      "call_locations": [
        {
          "trace_line": "#0 0x55d9c0a2b3f4 in vulnerable_function src/foo.c:42:5",
          "relative_file_path": "src/foo.c",
          "function": "vulnerable_function",
          "line_text": "memcpy(stack_buf, buf, len);",
          "line_number": 42,
          "symbol_offset": 1234,
          "symbol_size": 256,
          "key_index": "src/foo.c:40:5::int vulnerable_function(char *buf, size_t len)"
        }
      ]
    },
    {
      "reason": "allocate",
      "call_locations": [...]
    }
  ]
}
```

## Fields

### Top-Level
- **project_id**: CRS project identifier
- **scanner**: Source fuzzer (aflplusplus, libFuzzer, jazzer, syzkaller)
- **detection_strategy**: "fuzzing" or "static_analysis"
- **harness_id**: Which harness triggered the crash
- **crash_reason**: Crash type (heap-buffer-overflow, use-after-free, etc.)

### POI
- **reason**: Why this location is interesting
  - `crash_site`: Where crash occurred
  - `allocation_site`: Where vulnerable object was allocated
  - `free_site`: Where object was freed (for UAF)
  - `crashing_address_frame`: Stack frame for stack overflows

- **source_location**:
  - `relative_file_path`: File path relative to project root
  - `function_signature`: Full function signature with types
  - `line_text`: Actual source code line
  - `line_number`: Line number in file
  - `symbol_offset`: Offset from function start
  - `symbol_size`: Function size in bytes
  - `key_index`: Function index key (from clang-indexer format)

### Stack Traces
- **reason**: Stack trace category
  - `main`: Crash site stack
  - `allocate`: Allocation stack
  - `free`: Free stack
  - `crashing-address-frame`: Frame info for stack crashes

- **call_locations**: Array of stack frames (top to bottom)

## Integration

### Input
- Crash reports from Crash-Tracer
- ASAN/MSAN/UBSAN stack traces
- Sanitizer metadata

### Output
- POI reports (JSON)
- Consumed by:
  - **Invariant-Guy**: Insert probes at POI locations
  - **DyVA**: Trace variables at POI
  - **Patch Generation**: Focus patches on POI

## Related Components

- **[Crash-Tracer](../crash-analysis/crash-tracer.md)**: Provides crash reports
- **[Invariant-Guy](../crash-analysis/invariant-guy.md)**: Uses POI for tracing
- **[DyVA](../vuln-detection/dyva.md)**: Uses POI for root cause analysis
- **[Kumu-Shi-Runner](../crash-analysis/kumu-shi-runner.md)**: Alternative POI generation
