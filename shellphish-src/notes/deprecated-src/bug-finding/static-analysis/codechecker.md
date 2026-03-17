# CodeChecker

CodeChecker is an analysis tool built on Clang Static Analyzer that detects memory safety issues and coding errors in C/C++ code. The CRS integrates CodeChecker to identify locations and functions of interest for targeted fuzzing, particularly focusing on high-severity findings.

## Purpose

- Detect C/C++ memory safety issues (null pointers, buffer overflows, use-after-free)
- Generate locations of interest for targeted fuzzing (AFLrun)
- Identify functions of interest for prioritized analysis
- Leverage compiler-level analysis for low false positives

## Integration Approach

CodeChecker is a well-known tool. The CRS integration focuses on:
1. **Build-time analysis** during OSS-Fuzz compilation
2. **Function mapping** of findings using clang-indexer metadata
3. **High-severity filtering** for actionable results
4. **Extraction of locations/functions** for downstream targeting

## Workflow

### 1. Build-Time Analysis

**Pipeline Task**: `run_codechecker` in [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/pipeline.yaml#L15-L107)

**Build Process** ([Lines 70-95](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/pipeline.yaml#L70-L95)):
1. Create builder/runner images with `codechecker` instrumentation
2. Execute `oss-fuzz-build` with CodeChecker wrapper
3. Uses Bear to capture `compile_commands.json`
4. Runs `CodeChecker analyze` with `profile:security` checkers
5. Exports results to JSON format

### 2. Instrumentation Setup

**Location**: [`libs/crs-utils/.../instrumentation/codechecker/`](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/codechecker)

**Analysis Script**: [`compile_codechecker`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/codechecker/compile_codechecker#L1-L21)
```bash
# Capture compilation database
bear --output ${OUT}/compile_commands.json -- /compile

# Run CodeChecker analysis
CodeChecker analyze \
  compile_commands.json \
  --output ${OUT}/codechecker-reports \
  --analyzers clangsa \
  --enable-checker profile:security \
  || true

# Export to JSON
CodeChecker parse \
  ${OUT}/codechecker-reports \
  --export json \
  --output ${OUT}/codechecker-reports/report.json
```

**Checker Profile**: `profile:security` focuses on security-relevant checkers from Clang Static Analyzer

### 3. Report Parsing

**Script**: [`parse_codechecker_output.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/scripts/parse_codechecker_output.py)

**Version Check** ([Line 17](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/scripts/parse_codechecker_output.py#L17)):
- Asserts CodeChecker report format version 1

**Empty Report Handling** ([Lines 22-35](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/scripts/parse_codechecker_output.py#L22-L35)):
- If no findings: Falls back to dumping ALL functions from clang-indexer
- Ensures downstream components always have function data

**Severity Filtering** ([Line 37](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/scripts/parse_codechecker_output.py#L37)):
- Only processes HIGH severity reports
- Focus on critical security issues

**Function Mapping** ([Lines 54-79](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/scripts/parse_codechecker_output.py#L54-L79)):
1. Load function metadata from clang-indexer JSONs (`FUNCTION/*.json`)
2. For each finding:
   - Match by filename (basename comparison)
   - Check if issue line falls within function boundaries
   - Assign first matching function name
3. Output: `report_parsed.json` with function field added

### 4. Extraction for Targeting

**Script**: [`extract.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/scripts/extract.py)

**Locations of Interest** ([Lines 6-9](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/scripts/extract.py#L6-L9)):
```python
locs = {f"{r['file']['path']}:{r['line']}" for r in report}
```
Format: `file:line` (newline-delimited)

**Functions of Interest** ([Lines 11-14](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/scripts/extract.py#L11-L14)):
```python
funcs = {r['function'] for r in report if r['function'] is not None}
```
Format: Function names (newline-delimited, deduplicated)

## Output Formats

### CodeChecker Reports

**Raw Report** (`report.json`):
- CodeChecker version 1 format
- Fields: `file.path`, `line`, `column`, `checker_name`, `message`, `severity`, `analyzer_name`

**Parsed Report** (`report_parsed.json`):
- Enriched with `function` field from clang-indexer
- Only HIGH severity findings

### Targeting Outputs

**Locations of Interest** (`locs_of_interest`):
```
/src/project/file.c:42
/src/project/file.c:105
/src/project/other.cpp:73
```

**Functions of Interest** (`funcs_of_interest`):
```
vulnerable_function
process_input
handle_request
```

## Integration with AFLrun

**Consumer**: [`aflrun/pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflrun/pipeline.yaml#L58-L61)

**Usage** ([Lines 91-92](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflrun/pipeline.yaml#L91-L92)):
```yaml
AFLRUN_BUILD_BB_FILE: "{{ locs_of_interest | base64 }}"
```

AFLrun instruments binaries to target specific basic blocks at the locations identified by CodeChecker, enabling directed fuzzing toward potentially vulnerable code.

## Pipeline Configuration

### Resource Limits

From [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codechecker/pipeline.yaml#L20-L22):
- Job quota: 0.5 CPU, 500Mi memory (for pipeline execution)
- Build resources: 6 CPU, 26Gi memory (initial), up to 10 CPU, 40Gi (maximum)
- Priority: 2 (lower than most components)

### Current Status

**Pipeline Integration**: Currently **commented out** in main targets-c pipeline ([Lines 88-98](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/targets-c.yaml#L88-L98))

Indicates CodeChecker may be:
- Experimental or under development
- Computationally expensive for routine use
- Selectively enabled for specific projects

### Fault Tolerance

**Analysis Continuation** ([`compile_codechecker`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/codechecker/compile_codechecker)):
- `|| true` on CodeChecker analyze - continues even if some files fail
- Empty report fallback - always provides function data
- Graceful degradation ensures downstream components receive data

## Dependencies

**Upstream**:
- **Clang Indexer**: Provides function metadata for mapping findings
- **OSS-Fuzz**: Build infrastructure for instrumented compilation

**Downstream**:
- **AFLrun**: Consumes locations of interest for targeted fuzzing
- **(Potential) Analysis Pipeline**: Would integrate with broader static analysis workflow

## Key Features

### Compiler-Level Analysis

CodeChecker leverages Clang Static Analyzer, which has:
- Deep understanding of C/C++ semantics
- Access to full AST and type information
- Low false positive rate for memory safety issues
- Integration with compilation process

### Security Focus

**Profile:security** checker set targets:
- Null pointer dereferences
- Buffer overflows
- Use-after-free
- Double free
- Memory leaks
- Integer overflows
- Uninitialized variables

### Build Integration

**Generic Harness** ([`generic_harness.c`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/c-instrumentation/generic_harness.c)):
- Provides stub `LLVMFuzzerTestOneInput` implementation
- Enables analysis of projects without native fuzzing harnesses
- Uses `.shellphishshellphish` section for persistence

## Related Components

- **[Clang Indexer](./clang-indexer.md)**: Provides function boundary information
- **[AFLrun](../fuzzing/aflrun.md)**: Consumes locations for directed fuzzing
- **[CodeQL](./codeql.md)**: Complementary semantic analysis
