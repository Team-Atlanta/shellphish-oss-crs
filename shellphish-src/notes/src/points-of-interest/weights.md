# Weight System

## Overview

The CodeSwipe filter framework uses a weight-based scoring system to prioritize functions for vulnerability analysis. Each filter (Semgrep, CodeQL, LLuMinar, etc.) assigns weights to functions based on detected patterns, which are then aggregated into a final `priority_score` that determines the order of downstream analysis.

**Core Formula**: `priority_score = Σ (filter.weight)` - simple additive aggregation.

See [CodeSwipe Overview](codeswipe-overview.md) for the complete system architecture and workflow.

## Filter Summary Table

| Filter | Type | Weight Range | Basis | Description |
|--------|------|--------------|-------|-------------|
| **Semgrep** | Static Analysis | 2.0 - 23.0 | Severity + Vuln Type | Pattern-based vulnerability detection with severity and vulnerability type multipliers |
| **CodeQL** | Static Analysis | 1.0 - 8.0+ | Query Type | Dataflow-based semantic analysis with per-query weights |
| **LLuMinar (ScanGuy)** | LLM-Based | 0 or 10.0 | Binary Prediction | Fine-tuned LLM semantic vulnerability prediction |
| **DiffGuy** | Delta Mode | 2.0 - 12.0 | Diff Category | Differential analysis (overlap, boundary, function, file changes) - delta mode only |
| **Dangerous Functions** | Heuristic | 0.1 - 8.0 | API Risk Level | Unsafe C/C++ API detection and dangerous code patterns |
| **Static Reachability** | Reachability | 0 or 1.0 | Call Graph | Binary flag for functions reachable from entry points |
| **Dynamic Reachability** | Reachability | 0 or 1.0 | Runtime Coverage | Binary flag for functions covered during fuzzing |
| **Skip Tests** | Utility | 0.0 | Metadata Only | Test file identification (zeroes entire priority_score) |

## General Score Calculation

### Core Formula

For each function (CodeBlock), the priority score is calculated as:

```
priority_score = Σ (filter.weight)
```

Where the sum is taken over all enabled filters.

### Implementation

**Location**: [filter_framework.py L132-151](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/framework/filter_framework.py#L132-L151)

```python
def calculate_priority_scores(self, code_blocks: List[CodeBlock]) -> List[CodeBlock]:
    for block in code_blocks:
        total_score = 0.0
        should_skip = False

        # Iterate through all filter results for this function
        for result in block.filter_results.values():
            if result.metadata.get("is_test", False):
                should_skip = True  # Skip test files
                break
            total_score += result.weight  # Simple summation

        if should_skip:
            block.priority_score = 0.0
        else:
            block.priority_score = total_score  # Final score

    return code_blocks
```

### Key Properties

- **Additive**: All filter weights are summed (no multiplication or normalization)
- **No per-filter weighting**: Each filter has equal influence (can be changed in future)
- **Test filtering**: Test files automatically get `priority_score = 0` via Skip Tests filter metadata
- **Transparent**: Per-filter contribution visible in output for debugging

### Example Full Calculation

For function `parse_request`:

| Filter | Weight | Reason |
|--------|--------|--------|
| Semgrep | 23.0 | ERROR + out-of-bounds-write + deserialization |
| CodeQL | 8.0 | uaf + nullptr.gut |
| ScanGuy | 10.0 | LLM predicted vulnerable |
| DiffGuy | 12.0 | Overlap (changed + reachable + in modified file) |
| Dangerous Functions | 8.0 | Calls strcpy |
| Static Reachability | 1.0 | Reachable from harness |
| Dynamic Reachability | 1.0 | Covered by fuzz_parser harness |
| Skip Tests | 0.0 | Not a test file |

**Calculation**:
```
priority_score = 23.0 + 8.0 + 10.0 + 12.0 + 8.0 + 1.0 + 1.0 + 0.0 = 63.0
```

This function would rank very high in the output (top ~5%).

### Output Ranking

**Location**: [main.py L180-199](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L180-L199)

```python
# Sort by priority_score (descending)
ranked_functions = sorted(
    code_blocks,
    key=lambda x: x.priority_score,
    reverse=True
)

# Limit to top N (default: 100)
top_functions = ranked_functions[:output_limit]
```

Functions are sorted by `priority_score` in descending order, and only the top 100 (configurable) are output to downstream components.

## Semgrep Weights

### Severity-Based Weights

Location: [semgrep.py L66](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/semgrep.py#L66)

```python
sev_weights = {
    "ERROR": 10.0,     # Critical issues
    "WARNING": 5.0,    # Moderate issues
    "INFO": 2.0        # Minor issues
}
```

### Vulnerability-Type Weights

Location: [semgrep.py L67-71](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/semgrep.py#L67-L71)

```python
vuln_type_weights = {
    "jazzer": 10.0,                      # Jazzer sanitizer hooks (highest)
    "out-of-bounds-write": 9.0,          # Memory corruption
    "out-of-bounds-write-benign": 2.0,   # Lower priority OOB
    "deserialization": 4.0,              # Java deserialization
    "path-traversal": 2.5                # File system traversal
}
```

**Rationale**:
- `jazzer` patterns (10.0): Direct indicators of fuzzing-detected vulnerabilities
- `out-of-bounds-write` (9.0): High exploitability, memory corruption
- `deserialization` (4.0): High severity in Java applications
- `path-traversal` (2.5): Lower impact, context-dependent

### Weight Modes

Location: [semgrep.py L91-96](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/semgrep.py#L91-L96)

Three modes for combining weights:

1. **severity_only**:
   ```python
   weight = sum(sev_weights[sev] for sev in unique_severities)
   ```
   Use when trusting Semgrep's built-in severity classification.

2. **vuln_type**:
   ```python
   weight = sum(vuln_type_weights[vt] for vt in unique_vuln_types)
   ```
   Use when vulnerability type is more informative than severity.

3. **combined** (recommended):
   ```python
   weight = severity_total + vuln_type_total
   ```
   Maximum signal by combining both dimensions.

### Example Calculation

For a function with 2 Semgrep findings:
- Finding 1: severity="ERROR", vuln_type="out-of-bounds-write"
- Finding 2: severity="WARNING", vuln_type="deserialization"

**Combined mode**:
```
severity_total = 10.0 (ERROR, unique)
vuln_type_total = 9.0 + 4.0 = 13.0
final_weight = 10.0 + 13.0 = 23.0
```

## LLuMinar (ScanGuy) Weights

### LLM-Based Vulnerability Prediction

**Component**: [components/scanguy/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/scanguy)

**Filter Integration**: [scanguy.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/scanguy.py)

LLuMinar uses a fine-tuned LLM (Qwen2.5-7B-Instruct) to perform semantic vulnerability analysis beyond pattern matching.

### How It Works

1. **Input**: All functions reachable from harness entry points
2. **Analysis**: LLM predicts vulnerability with reasoning
3. **Output**: `scan_results.json` with predictions

**Example Output**:
```json
{
  "function_index_key": "file.c:func:123",
  "predicted_is_vulnerable": "yes",
  "predicted_vulnerability_type": "CWE-416",
  "output": "The function uses freed memory in line 45..."
}
```

### Weight Assignment

Location: [scanguy.py L89-95](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/scanguy.py#L89-L95)

```python
if prediction["predicted_is_vulnerable"] == "yes":
    weight = configured_weight  # Typically 10.0
else:
    weight = 0.0
```

**Rationale**: Binary decision (vulnerable vs. not) with configurable weight for predicted vulnerabilities.

## DiffGuy Weights

### Differential Analysis for Delta Mode

**Component**: [components/diffguy/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/diffguy)

**Filter Integration**: [diffguy.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py)

DiffGuy analyzes changes between two codebase versions (before/after patch) to prioritize modified or newly vulnerable functions.

### Three Analysis Modes

1. **Function Diff** ([funcAnalyzer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/funcAnalyzer.py))
   - Compares CodeQL vulnerability query results before/after
   - Identifies functions with **new or changed vulnerability patterns**

2. **Boundary Diff** ([boundaryAnalyzer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/boundaryAnalyzer.py))
   - Detects functions that **became reachable** from harness entry points
   - Captures API surface expansion

3. **File Diff** ([fileAnalyzer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/fileAnalyzer.py))
   - Identifies functions in **modified files**
   - Uses LLM to validate security relevance

### Category-Based Weights

Location: [diffguy.py L74-109](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py#L74-L109)

```python
# Overlap of all three categories (highest priority)
if key in overlap:
    weight = 12.0  # Changed + newly reachable + in modified file

# Combinations of two categories
elif key in boundary_diff and key in function_diff:
    weight = 7.0   # Changed AND became reachable

elif key in boundary_diff and key in file_diff:
    weight = 6.0   # Newly reachable in modified file

elif key in function_diff and key in file_diff:
    weight = 4.0   # Changed pattern in modified file

# Single category matches
elif key in boundary_diff:
    weight = 4.0   # Function boundary shifted

elif key in file_diff:
    weight = 3.0   # File was touched

elif key in function_diff:
    weight = 2.0   # Function implementation changed
```

**Weight Rationale**:
- **12.0**: Overlap indicates comprehensive change (all signals agree)
- **7.0**: High impact (vulnerability pattern changed AND became reachable)
- **6.0**: Exposure change (newly reachable in modified code)
- **4.0**: Moderate signal (single strong indicator or two weak ones)
- **3.0**: File proximity (in changed file)
- **2.0**: Function-level change detected

### Example Calculation

For a function after a security patch:
- In `function_diff`: Yes (new buffer overflow pattern detected)
- In `boundary_diff`: Yes (became public after refactoring)
- In `file_diff`: Yes (in `parser.c` which was modified)

```
Category: overlap
DiffGuy weight = 12.0
```

### Use Case

**Delta Mode Only**: DiffGuy is specifically designed for analyzing patches and code deltas, not for full codebase scans.

## Dangerous Functions Weights

### Pattern-Based API Detection

Location: [dangerous_functions.py L14-49](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L14-L49)

Detects calls to unsafe C/C++ APIs and dangerous code patterns.

### API Weights

```python
__DANGEROUS_FUNCTIONS__ = {
    "gets": 8.0,      # Unbounded input (critical)
    "strcpy": 8.0,    # No bounds checking (critical)
    "system": 8.0,    # Command injection risk (critical)
    "strcat": 4.0,    # Potential overflow (high)
    "exec": 4.0,      # Code execution risk (high)
    "free": 1.5,      # Memory management (medium)
    "fgets": 0.5,     # Safe but noteworthy (low)
    "memcpy": 0.1,    # Common, context-dependent (very low)
}
```

### Code Structure Weights

```python
__DANGEROUS_CODE_STRUCTURES__ = {
    "for ": 0.5,      # Loop iterations (potential for off-by-one)
    "for(": 0.5,
    "while ": 0.3,    # Loop iterations
    "while(": 0.3,
}
```

**Weight Calculation**: Additive (all matches summed)

**Example**:
```c
void parse(char* input) {
    char buf[100];
    strcpy(buf, input);  // +8.0
    for (int i = 0; ...)  // +0.5
}
// Total: 8.5
```

## CodeQL Weights

### C/C++ Vulnerability Weights

Location: [codeql.py L97-111](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/codeql.py#L97-L111)

```python
c_vuln_weights = {
    # Critical memory safety issues
    "double_free": 5,              # High priority
    "uaf": 5,                      # Use-after-free (high priority)

    # Allocation pattern heuristics
    "alloc_const": 2,              # Constant allocation
    "alloc_const_df": 2,           # Constant allocation dataflow
    "alloc_then_arr": 2,           # Allocation + array access
    "alloc_then_loop": 2,          # Allocation + loop pattern
    "alloc_then_mem": 2,           # Allocation + memory operation
    "alloc_checks": 2,             # Allocation validation

    # Stack buffer patterns
    "stack_buf_loop": 3,           # Stack buffer in loop
    "stack_const_alloc": 3,        # Constant stack allocation

    # Null pointer (noisy)
    "nullptr": 1,                  # General null check (REALLY noisy)
    "nullptr.gut": 3,              # GUT variant
    "nullptr.naive": 3             # Naive detection
}
```

**Weight Rationale**:
- **5**: Critical vulnerabilities (double free, UAF) - immediate exploitation
- **3**: Suspicious patterns (stack buffers, better null checks) - likely bugs
- **2**: Heuristic patterns (allocation anomalies) - potential issues
- **1**: Noisy checks (general nullptr) - many false positives

### Java Vulnerability Weights

Location: [codeql.py L81-95](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/codeql.py#L81-L95)

```python
java_vuln_weights = {
    # Critical injection vulnerabilities (weight: 5)
    "CommandInjection": 5,          # OS command execution
    "Deserialization": 5,           # Object deserialization RCE
    "ServerSideRequestForgery": 5,  # SSRF
    "XXEInjection": 5,              # XML external entity

    # Medium injection vulnerabilities (weight: 4)
    "SqlInjection": 4,              # Database injection
    "XPathInjection": 4,            # XPath query injection
    "ScriptEngineInjection": 4,     # Script evaluation
    "ExpressionLanguage": 4,        # EL injection
    "LdapInjection": 4,             # LDAP injection
    "NamingContextLookup": 4,       # JNDI lookup
    "ReflectionCallInjection": 4,   # Reflection abuse
    "RegexInjection": 4,            # ReDoS

    # File system (weight: 3)
    "PathTraversal": 3              # Directory traversal
}
```

**Weight Rationale**:
- **5**: Remote Code Execution (RCE) potential
- **4**: Data exfiltration, privilege escalation, or DoS
- **3**: File system access, information disclosure

### Example Calculation

For a C function with CodeQL hits:
- Query: uaf (weight: 5)
- Query: nullptr.gut (weight: 3)

```python
codeql_weight = 5 + 3 = 8
```



## Downstream Consumption

### How Components Use priority_score

**AIJON (Fuzzing Instrumentation)**:

Location: [codeswipe_poi.py L24-29](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/aijon-lib/aijon_lib/poi_interface/codeswipe_poi.py#L24-L29)

- Sorts functions by priority_score, takes top 100
- Instruments high-score functions for guided fuzzing
- Higher priority_score → more fuzzing budget allocated

**Discovery Guy (PoC Generation)**:

Location: [main.py L352](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/discoveryguy/src/discoveryguy/main.py#L352)

- Processes functions in priority_score ranking order
- LLM-based PoC generation focuses on high-score functions first
- Time budget allocated proportionally to priority_score

**Fuzzing Agents**:

- AFLuzzer: Prioritize harnesses reaching high-score functions
- Jazzmine: Focus sanitizer hooks on top-ranked sinks
- Grammar Guy: Generate inputs targeting high-priority parsers

**QuickSeed (Seed Generation)**:

- Consults metadata to identify vulnerability types
- Generates seeds tailored to high-priority sinks
- Example: SQL injection seeds for high-score database functions

## Weight Tuning Guidelines

### Increasing Detection for Specific Vulnerability Classes

**Example**: Prioritize memory corruption over injection vulnerabilities

In [codeql.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/codeql.py):

```python
c_vuln_weights = {
    "double_free": 10,  # Increased from 5
    "uaf": 10,          # Increased from 5
    ...
}

java_vuln_weights = {
    "CommandInjection": 3,  # Decreased from 5
    "SqlInjection": 2,      # Decreased from 4
    ...
}
```

### Balancing False Positives

**Example**: Reduce weight for noisy queries

```python
c_vuln_weights = {
    "nullptr": 0,  # Disable completely (was 1)
    ...
}
```

### Adding New Vulnerability Types

**Example**: Add weight for new Semgrep rule

In [semgrep.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/semgrep.py):

```python
vuln_type_weights = {
    ...
    "integer-overflow": 7.0,  # New vulnerability type
}
```

### Filter-Level Weighting (Future Enhancement)

Currently all filters have equal influence. To give CodeQL more weight than Semgrep:

```python
# Hypothetical future implementation in filter_framework.py
filter_multipliers = {
    "codeql": 2.0,    # Double CodeQL's contribution
    "semgrep": 1.0,   # Keep Semgrep at baseline
    "scanguy": 1.5,   # 50% boost for LLM predictions
}

for filter_name, result in block.filter_results.items():
    total_score += result.weight * filter_multipliers.get(filter_name, 1.0)
```

## Design Decisions

### Why Simple Summation?

**Current Approach**: `priority_score = Σ(filter.weight)`

**Advantages**:
- Transparent and debuggable
- No hyperparameter tuning required
- Per-filter contribution visible in output
- Easy to understand and modify

**Alternatives Considered**:
- **Weighted sum**: Requires tuning filter-level multipliers
- **Max pooling**: Ignores complementary signals
- **ML-based ranking**: Requires ground truth labels

### Why No Normalization?

Weights are **not normalized** across filters, allowing:
- Filters with more findings to contribute more
- Absolute weight scales have semantic meaning
- Easy addition of new filters without rebalancing

**Trade-off**: Filter authors must coordinate weight scales.

### Future Enhancements

Potential improvements noted in [filter_framework.py L130](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/framework/filter_framework.py#L130):

```python
# TODO: Implement more sophisticated scoring
# For now, just sum the weights from each filter
```

**Possible Extensions**:
1. **Cross-filter boosting**: Higher weight when multiple filters agree
2. **Historical feedback**: Adjust weights based on PoC success rate
3. **Context-aware weighting**: Use call graph depth, complexity metrics
4. **Diminishing returns**: Sublinear aggregation for multiple findings

## References

- **Filter Framework**: [filter_framework.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/framework/filter_framework.py)
- **Semgrep Filter**: [semgrep.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/semgrep.py)
- **CodeQL Filter**: [codeql.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/codeql.py)
- **Output Models**: [ranking.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/models/ranking.py)
- **AIJON POI Interface**: [codeswipe_poi.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/aijon-lib/aijon_lib/poi_interface/codeswipe_poi.py)
