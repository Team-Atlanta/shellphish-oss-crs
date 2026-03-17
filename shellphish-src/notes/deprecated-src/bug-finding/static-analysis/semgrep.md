# Semgrep

Semgrep is an open-source static analysis tool that uses pattern matching to detect security vulnerabilities. The CRS integrates Semgrep for fast, rule-based scanning of C/C++ and Java code, mapping findings to specific functions using the function resolver.

## Purpose

- Fast pattern-based vulnerability detection
- Scan for known vulnerability patterns (path traversal, deserialization, SQL injection, etc.)
- Map findings to function boundaries for targeted analysis
- Support delta mode for analyzing only changed code

## Integration Approach

Semgrep is a well-known tool. The CRS integration focuses on:
1. **Custom rule sets** tailored for CWE detection
2. **Function-level mapping** of findings using function indices
3. **Dual output formats** (raw findings + function-grouped)
4. **Delta mode support** for base/patched code comparison

## Workflow

### Execution Pipeline

**Main Script**: [`semgrep.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py)

**SemgrepAnalysis Class** ([Lines 121-415](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L121-L415)):

1. **Git Configuration** ([Lines 377-379](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L377-L379)): Mark repo as safe directory

2. **Rule Validation** ([Lines 381-386](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L381-L386)):
   - Method: `_validate_rules()` ([Lines 147-179](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L147-L179))
   - Validates all `.yml`/`.yaml` files against Pydantic models
   - Ensures required `vuln_type` metadata field exists

3. **Semgrep Execution** ([Lines 388-395](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L388-L395)):
   - Method: `_run_semgrep_on_rules()` ([Lines 221-260](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L221-L260))
   - Command: `semgrep scan --config <rule_file> <repo_path> --json`
   - Processes each rule file independently

4. **Function Mapping** ([Lines 397-399](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L397-L399)):
   - Method: `_process_vulnerable_functions()` ([Lines 262-321](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L262-L321))
   - Uses function resolver to map line numbers to function boundaries
   - Groups findings by function

5. **Output Generation** ([Lines 405-406](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L405-L406)):
   - Raw findings JSON (all findings + summary stats)
   - Vulnerable functions JSON (function-level grouping)

## Rule Sets

### Rule Structure

**Schema**: Pydantic models ([Lines 24-83](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L24-L83))

**SemgrepMetadata** ([Lines 25-57](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L25-L57)):
- **Required**: `vuln_type` (one of 14 allowed types)
- **Allowed Types**: `path-traversal`, `ssrf`, `out-of-bounds-write`, `sql-injection`, `command-injection`, `buffer-overflow`, `use-after-free`, `null-pointer-dereference`, `integer-overflow`, `format-string`, `deserialization`, `hardcoded-credentials`, `jazzer`

**SemgrepRule** ([Lines 59-79](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L59-L79)):
- Required: `rule_id`, `message`, `severity`, `languages`, `metadata`
- Severity: ERROR, WARNING, INFO

### Rule Categories

**Java Rules** ([`rules/java/`](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/semgrep/rules/java)):
- **Path Traversal**: [`path-traversal/2-zip-slip.yml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/path-traversal/2-zip-slip.yml) (13 rules)
  - `zip-slip.resolve-no-normalize`
  - `zip-slip.unchecked-file-without-validation`
  - `zip-slip.zipentry-file-write`
  - 10 more variants

- **Deserialization**: [`deserialization/`](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/semgrep/rules/java/deserialization)
  - Detects `ObjectInputStream.readObject()` patterns

- **CVE-Specific**: [`cwe_bench/`](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/semgrep/rules/java/cwe_bench)
  - Historical CVE patterns (DSpace CVE-2016-10726, Spark CVE-2018-9159, etc.)

**C/C++ Rules** ([`rules/c/`](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/semgrep/rules/c)):
- **Out-of-Bounds**: [`out-of-bounds/invalid-sizeof-comparisons.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/c/out-of-bounds/invalid-sizeof-comparisons.yaml)
  - Detects `var <= sizeof(array)` patterns

### Language Selection

Pipeline logic ([Lines 95-100](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/pipeline.yaml#L95-L100)):
```bash
TARGET_LANG={{project_metadata.language}}
if [ "$TARGET_LANG" = "jvm" ]; then
  TARGET_LANG="java"
elif [ "$TARGET_LANG" = "c++" ] || [ "$TARGET_LANG" = "c" ]; then
  TARGET_LANG="c"
fi
```

Rules directory: `/shellphish_semgrep_rules/$TARGET_LANG`

## Function Resolution

### Resolver Selection

**Constructor** ([Lines 134-141](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L134-L141)):
- **Local Mode** (`local_run=True`): Uses `LocalFunctionResolver` with file paths
- **Remote Mode** (`local_run=False`): Uses `RemoteFunctionResolver` with API

### Mapping Algorithm

**Method**: `_process_vulnerable_functions()` ([Lines 262-321](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L262-L321))

1. Group findings by file path
2. For each file:
   - Query function resolver for all functions in file ([Line 276](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L276))
   - Build `line_to_function` mapping ([Lines 277-280](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L277-L280))
   - Map each finding to containing function ([Lines 286-290](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L286-L290))
3. Create `VulnerableFunction` objects with all findings per function

## Output Formats

### Raw Findings JSON

**Structure** ([Lines 350-361](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L350-L361)):
```json
{
  "repo_path": "string",
  "total_findings": int,
  "findings_by_severity": {"ERROR": int, "WARNING": int},
  "findings_by_rule": {"rule_id": int},
  "findings": [
    {
      "check_id": "string",
      "severity": "string",
      "file_path": "string",
      "start_line": int,
      "message": "string",
      "vuln_type": "string",
      "end_line": int
    }
  ]
}
```

### Vulnerable Functions JSON

**Structure** ([Lines 363-370](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/semgrep.py#L363-L370)):
```json
{
  "function_key": {
    "function_key": "string",
    "number_of_findings": int,
    "findings": [...],
    "function_name": "string",
    "file_path": "string",
    "start_line": int,
    "end_line": int
  }
}
```

## Pipeline Configuration

### Tasks

**`semgrep_analysis`** ([Lines 24-111](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/pipeline.yaml#L24-L111)):
- Current/patched code analysis
- Job quota: 1 CPU, 1Gi memory
- Exit trap ensures pipeline continues on errors

**`semgrep_analysis_base`** ([Lines 112-209](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/pipeline.yaml#L112-L209)):
- Base/unpatched code analysis for delta mode
- Triggered by `delta_mode_tasks` input
- Same configuration as main task

### Empty Output Initialization

Both tasks create empty outputs at startup ([Lines 78-89](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/pipeline.yaml#L78-L89)):
```bash
cat > {{ semgrep_analysis_raw_findings }} << EOF
{
  "repo_path": "{{ project_analysis_source }}",
  "total_findings": 0,
  "findings_by_severity": {},
  "findings_by_rule": {},
  "findings": []
}
EOF
echo '{}' > {{ semgrep_analysis_report }}
```

Ensures downstream components always receive valid JSON.

## Delta Mode

**Purpose**: Compare patched vs unpatched code to identify:
- New vulnerabilities introduced by patches
- Vulnerabilities fixed by patches
- Unchanged vulnerabilities

**Implementation**:
1. Run `semgrep_analysis` on current code
2. Run `semgrep_analysis_base` on base code (if `delta_mode_tasks` present)
3. Downstream comparison components analyze differences

## Key Features

### Graceful Error Handling

**Exit Trap** ([Lines 90-91](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/pipeline.yaml#L90-L91)):
```bash
trap 'exit 0' EXIT
```
Task always exits with success, allowing pipeline to continue even on Semgrep errors.

### Test File Exclusion

**Pitfall**: [`pitfalls.md`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/pitfalls.md)
- Semgrep ignores test files by default
- Reference: https://semgrep.dev/docs/ignoring-files-folders-code#understand-semgrep-defaults

### Resource Efficiency

- Single CPU core per analysis
- 1GB memory limit
- Typically completes in minutes
- Low overhead compared to semantic analysis

## Dependencies

**Upstream**:
- **Function Index Generator**: Provides function indices
- **Clang Indexer**: Provides function metadata (via indices)

**Downstream**:
- **Vulnerability aggregation**: Combined with CodeQL results
- **Code-swipe**: Likely consumes reports for prioritization

## Testing

**Backup Testing**: [`unpack-backup.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/unpack-backup.sh)
- Interactive script for testing against backup data
- Allows rebuilding targets with OSS-Fuzz
- Integrates with backup handling utilities

## Related Components

- **[CodeQL](./codeql.md)**: Complementary semantic analysis
- **[Function Index Generator](./function-index-generator.md)**: Provides function resolution
- **[Scanguy](./scanguy.md)**: AI-based vulnerability detection
