# CodeQL

CodeQL is GitHub's semantic code analysis engine that uses dataflow and control flow queries to detect security vulnerabilities. The CRS integrates CodeQL for C/C++ and Java analysis, running security queries, building call graphs, and uploading results to Neo4j for graph-based reasoning.

## Purpose

- Detect CWE security vulnerabilities through semantic analysis
- Build comprehensive call graphs with direct and indirect call relationships
- Generate seeds for targeted fuzzing via taint analysis (quickseed)
- Support delta mode for analyzing only changed code

## Integration Approach

CodeQL is a well-known tool. The CRS integration focuses on:
1. **Automated database creation** during OSS-Fuzz builds
2. **Pre-compiled query packs** for fast execution
3. **Neo4j integration** for call graph storage
4. **Function resolution** to map findings to specific functions
5. **Delta mode** for incremental analysis

## Workflow

### 1. Database Creation

**Task**: `codeql_build` in [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/pipeline.yaml#L191-L334)

- Uses OSS-Fuzz build with `shellphish_codeql` instrumentation
- Calls [`codeql_build.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/guest_content/codeql_build.py) during compilation to create database
- Language mapping via [`to_codeql_lang.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/guest_content/to_codeql_lang.sh) (C/C++→cpp, Java→java)
- Database stored at `/work/.sss-codeql-database` and uploaded as zip

**Delta Mode**: `codeql_build_base` task builds database at HEAD~1 for comparison

### 2. Call Graph Analysis

**Task**: `codeql_analysis_graph` in [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/pipeline.yaml#L336-L424)

**Implementation**: [`analysis_query.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/callgraph/analysis_query.py)

**Language-Specific Call Graphs**:
- **C/C++**: [`callgraph_c.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/callgraph/callgraph_c.py) - `BetterCallGraph` class
  - Direct calls, reflected calls, function pointers
  - Global variable access patterns
- **Java**: [`callgraph_java.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/callgraph/callgraph_java.py) - `JavaCallGraph` class
  - Uses `callGraph.ql` and `allFuncs.ql` queries

**Neo4j Upload** ([Lines 348-413](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/callgraph/analysis_query.py#L348-L413)):
- Creates `CFGFunction` nodes for all functions
- Creates `DIRECTLY_CALLS` and `MAYBE_INDIRECT_CALLS` edges
- Batch processing: 500 functions, 1000 calls per batch
- Function resolution via LocalFunctionResolver or RemoteFunctionResolver

### 3. CWE Vulnerability Queries

**Task**: `codeql_cwe_queries` in [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/pipeline.yaml#L525-L621)

**Implementation**: [`run_cwe_queries.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/cwe_queries/run_cwe_queries.py)

**Query Execution** ([Lines 240-260](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/cwe_queries/run_cwe_queries.py#L240-L260)):
```bash
codeql database analyze \
  --format=sarif-latest \
  --threads=0 \
  --ram=11264 \
  --timeout=1800 \
  --additional-packs=/shellphish/codeql_compiled_packs \
  <database> \
  <query_suite>
```

**Query Suites**:
- **Java**: `java-security-experimental.qls`, `java-security-extended.qls`
- **C/C++**: `cpp-security-experimental.qls`, `cpp-security-extended.qls`

**Pre-Compiled Query Packs** ([Dockerfile Lines 14-24](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/Dockerfile#L14-L24)):
- Downloaded from private GitHub mirror repository
- Includes: `java-queries`, `java-all`, `cpp-queries`, `cpp-all`
- Speeds up query execution significantly

**Result Processing** ([Lines 292-420](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/cwe_queries/run_cwe_queries.py#L292-L420)):
- Parses SARIF reports using `SarifResolver`
- Filters findings: Must have CWE tags, severity="error"
- **Allowlisted rules** ([Line 38](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/cwe_queries/run_cwe_queries.py#L38)): `java/toctou-race-condition`, `java/relative-path-command` (bypass filtering)
- Extracts code flow functions and related locations
- Groups by function identifier (keyindex)

**Neo4j Upload** ([Lines 68-194](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/cwe_queries/run_cwe_queries.py#L68-L194)):
- Creates `CWEVulnerability` nodes
- Creates `HAS_CWE_VULNERABILITY` relationships with properties:
  - `line_number`: Location
  - `codeflow_functions`: Call paths leading to vulnerability
  - `related_locations_functions`: Contextual function references

### 4. Quickseed Queries

**Task**: `quickseed_codeql_query` in [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/pipeline.yaml#L426-L523)

**Java Path** ([Lines 508-510](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/pipeline.yaml#L508-L510)):
- [`run_quickseed_query.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/run_quickseed_query.py): Uses Jinja2 templates to generate taint queries
- [`jazzer_sink_methods.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml): 13 sink categories (CommandInjection, PathTraversal, SSRF, etc.)
- [`java_vuln_query/exec.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/java_vuln_query/exec.py): Generates report with functions calling sinks

**C/C++ Path** ([Lines 511-514](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/pipeline.yaml#L511-L514)):
- [`c_vuln_query/exec.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/exec.py): Runs custom vulnerability queries
- Custom queries: `nullptr.ql`, `uaf.ql`, `double_free.ql`, `stack_buf_loop.ql`, etc.

## Output Formats

### SARIF Reports
- **Raw SARIF**: `codeql_cwe_sarif_report` - Direct CodeQL output
- **Enriched Report**: `codeql_cwe_report` - Function-indexed with metadata

### Enriched Report Format
```json
{
  "metadata": {
    "language": "jvm",
    "total_vulnerable_functions": N,
    "total_vulnerabilities": M,
    "findings_per_rule_id": {"rule_id": count}
  },
  "vulnerable_functions": {
    "function_identifier": {
      "results": [
        {
          "rule_id": "...",
          "message": "...",
          "start_line": N,
          "cwe_tags": ["cwe-22"],
          "code_flow_functions": {"0": ["func1", "func2"]},
          "related_locations_functions": ["func3"]
        }
      ]
    }
  }
}
```

### Neo4j Graph Schema
- **Nodes**: `CFGFunction`, `CWEVulnerability`, `CFGGlobalVariable`
- **Relationships**:
  - `DIRECTLY_CALLS`, `MAYBE_INDIRECT_CALLS` (call graph)
  - `HAS_CWE_VULNERABILITY` (vulnerability mapping)
  - `takes_pointer_of_function` (function pointers)

## Delta Mode

**Trigger**: Presence of `delta_mode_tasks` input

**Base Analysis**: `codeql_cwe_queries_base` task ([Lines 622-722](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/pipeline.yaml#L622-L722))
- Runs CWE queries on HEAD~1 database
- Skips Neo4j upload (`--skip-analysis-graph` flag) to preserve HEAD findings
- Enables vulnerability regression tracking

## Key Features

### Function Resolution
- **Local Mode**: Uses function indices from clang-indexer
- **Remote Mode**: Queries function resolver service
- Maps CodeQL locations (`file:///path:line:col:line:col`) to function identifiers

### Batch Processing
- Function registration: 500 per batch
- Call relationships: 1000 per batch
- Java relationships: 5000 per Neo4j transaction
- Prevents memory issues for large projects

### Error Handling
- 30-minute timeout for CWE queries
- Empty report structure on failure
- Pipeline continues even if analysis fails
- Buildless database fallback for languages that support it

## Configuration

### Resource Requirements
- CPU: Uses all available threads (`--threads=0`)
- Memory: 11264 MB for query execution
- Timeout: 1800 seconds (30 minutes)

### Environment Variables
- `CODEQL_SERVER_URL`: CodeQL server endpoint (default: `http://172.17.0.1:4000`)
- `ANALYSIS_GRAPH_BOLT_URL`: Neo4j connection (format: `bolt://user:pass@host:port`)
- `FUNCTION_INDEX_PATH`, `FUNCTION_JSON_DIR`: For function resolution

## Dependencies

**Upstream**:
- **Clang Indexer**: Provides function indices for resolution
- **OSS-Fuzz Build**: Creates instrumented builds for database creation

**Downstream**:
- **Scanguy**: Uses call graph for context
- **Grammar-Guy**: Uses vulnerability findings for targeted grammar
- **Patch Components**: Use CWE findings for patch targets
- **POV Generation**: Uses findings for exploit creation

## Testing

**Backup-Based Testing**: [`run_from_backup.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/run-from-backup.sh)
- Interactive project selection
- Database upload and function resolver initialization
- Runs call graph analysis from backups

**CWE Query Testing**: [`cwe_queries/run_from_backup.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/cwe_queries/run_from_backup.sh)
- Tests CWE query execution
- Supports delta mode testing
- Interactive Neo4j upload

## Related Components

- **[Function Index Generator](./function-index-generator.md)**: Provides function resolution
- **[Semgrep](./semgrep.md)**: Complementary pattern-based analysis
- **[Scanguy](./scanguy.md)**: Uses call graph for LLM context
