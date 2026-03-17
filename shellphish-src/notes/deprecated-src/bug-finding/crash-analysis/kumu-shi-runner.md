# Kumu-Shi-Runner

Kumu-Shi-Runner integrates the Kumu-Shi taint analysis and exploit generation framework into the CRS pipeline. It performs dataflow analysis from input bytes to crash sites using CodeQL and generates exploit primitives.

## Purpose

- Taint analysis for crashes
- Track dataflow from input to crash
- Generate exploit primitives
- Identify exploitable crashes
- Provide POI (Points of Interest) reports

## CRS-Specific Usage

**Integration Points**:
- CodeQL database for taint queries
- Function indices from clang-indexer
- Crash inputs from fuzzers
- POI reports for downstream analysis

**Installation** ([README.md](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/kumu-shi-runner/README.md)):
```bash
./setup.sh

# Requires CodeQL in PATH
# Download: https://github.com/github/codeql-action/releases/download/codeql-bundle-v2.18.4/codeql-bundle-linux64.tar.gz
```

## Usage

**Command Line** ([README.md Lines 13-19](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/kumu-shi-runner/README.md#L13-L19)):
```bash
kumu-shi \
  --target-root /path/to/source \
  --crash-input ./crashing_seeds/crash_abc123 \
  --report-yaml ./poi.yaml \
  --function-json-dir ./function_out_dir/ \
  --function-indices ./function_indices.json \
  --codeql-db /path/to/codeql-db \
  --codeql-executable /path/to/codeql/codeql
```

**Arguments**:
- `--target-root`: Source code directory
- `--crash-input`: Crashing input file
- `--report-yaml`: Output POI report path
- `--function-json-dir`: Function metadata directory (from function-index-generator)
- `--function-indices`: Function index file (from clang-indexer)
- `--codeql-db`: CodeQL database path
- `--codeql-executable`: CodeQL CLI binary

## Workflow

### 1. Input Analysis
- Parse crash input file
- Identify input structure
- Determine taint sources

### 2. Taint Tracking (CodeQL)
- Query CodeQL database for dataflow
- Track input bytes through program
- Identify taint sinks at crash site
- Build taint graph

### 3. POI Identification
- Locate variables influenced by input
- Identify crash-relevant computations
- Extract function signatures from indices
- Generate POI report

### 4. Output (POI Report)
```yaml
project_id: "proj-123"
crash_report_id: "crash-789"

points_of_interest:
  - location: "/src/foo.c:42"
    function: "vulnerable_function"
    reason: "crash_site"
    variables: ["buf", "buf_len"]
    taint_sources: ["input_byte_0", "input_byte_4"]

  - location: "/src/foo.c:30"
    function: "allocate_buffer"
    reason: "allocation_site"
    variables: ["size"]
    taint_sources: ["input_byte_4"]
```

## Pipeline Integration

### C/C++ Pipeline ([pipeline.yaml Lines 1-100](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/kumu-shi-runner/pipeline.yaml#L1-L100))
```yaml
# Uses CodeQL database from codeql component
# Depends on:
#   - codeql_db_ready
#   - full_functions_indices
#   - function_by_file_indices
#   - representative_crashing_inputs
```

### Java Pipeline ([pipeline-java.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/kumu-shi-runner/pipeline-java.yaml))
```yaml
# Similar structure for Java targets
# Uses Jazzer-specific analysis
```

## Integration with Invariant-Guy

**Flow**:
1. Kumu-Shi-Runner generates POI report
2. Invariant-Guy reads POI report
3. Invariant-Guy inserts probes at POI locations
4. Invariant-Guy mines invariants for POI variables

## Related Components

- **[CodeQL](../static-analysis/codeql.md)**: Provides database for taint queries
- **[Clang Indexer](../static-analysis/clang-indexer.md)**: Provides function indices
- **[Function Index Generator](../static-analysis/function-index-generator.md)**: Provides function metadata
- **[Invariant-Guy](./invariant-guy.md)**: Uses POI reports for invariant mining
- **[POI-Guy](../pov-generation/poi-guy.md)**: Alternative POI generation approach
