# Quickseed

Quickseed generates targeted seeds using CodeQL taint analysis to create inputs that reach specific sinks in the code.

## Purpose

- Taint-based seed generation
- Create seeds targeting specific code paths
- Use CodeQL dataflow tracking
- Generate inputs that reach vulnerability sinks

## CRS-Specific Usage

**Pipeline**: [`components/codeql/quickseed_query/`](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/codeql/quickseed_query)

**Integration with CodeQL** ([codeql/pipeline.yaml Lines 426-523](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/pipeline.yaml#L426-L523)):

**Java Path**:
- `run_quickseed_query.py`: Jinja2 templates for taint queries
- `jazzer_sink_methods.yaml`: 13 sink categories (CommandInjection, PathTraversal, SSRF, etc.)
- Finds functions calling dangerous sinks

**C/C++ Path**:
- Custom queries: `nullptr.ql`, `uaf.ql`, `double_free.ql`, etc.
- Identifies memory safety issues
- Generates seeds for vulnerability locations

**Workflow**:
1. CodeQL identifies sinks (dangerous functions)
2. Taint analysis finds paths from input to sinks
3. Generate seeds that follow those paths
4. Seeds designed to reach specific vulnerabilities

**Output**: `quickseed_codeql_reports` and `discovery_vuln_reports`

## Related Components

- **[CodeQL](../static-analysis/codeql.md)**: Provides taint analysis
- **[Corpus-Guy](./corpus-guy.md)**: Complementary seed generation
