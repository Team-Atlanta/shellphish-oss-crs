# DiffGuy Filter (Delta Mode)

## Overview

The **DiffGuy Filter** performs differential analysis between two versions of a codebase (before/after a patch or code change) to identify and prioritize functions that are most likely to have introduced or exposed new vulnerabilities. This filter is **only active in delta mode** (when comparing code versions).

**Purpose**: In delta mode, prioritize changed functions, newly reachable functions, and functions in modified files to focus analysis resources on patch-related changes.

**Location**:
- **Filter**: [diffguy.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py)
- **Component**: [components/diffguy/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/diffguy)

## How It Works

### Architecture

DiffGuy runs as a **separate component** before CodeSwipe and generates a report (`diffguy_report.json`) that the DiffGuy Filter consumes.

```
Input: Before/After Codebase Versions
    ↓
DiffGuy Component (Differential Analysis)
    ├─ Function Diff Analyzer
    ├─ Boundary Diff Analyzer
    └─ File Diff Analyzer
    ↓
diffguy_report.json
    ↓
DiffGuy Filter (CodeSwipe)
    ↓
Weight Assignment based on diff categories
```

### Three Analysis Dimensions

DiffGuy performs three independent types of analysis ([lines 23-26](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py#L23-L26)):

#### 1. Function Diff

**Purpose**: Identify functions with **changed vulnerability patterns** detected by CodeQL.

**Analyzer**: [funcAnalyzer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/funcAnalyzer.py)

**Method** ([funcAnalyzer.py L64-77](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/funcAnalyzer.py#L64-L77)):
1. Run CodeQL vulnerability queries on before/after versions
2. Compare query results per function
3. Flag functions with new or different vulnerability findings

**Example**:
```python
# Before version: No findings
def parse_input(data):
    return data

# After version: New buffer overflow detected by CodeQL
def parse_input(data):
    buffer = malloc(100)
    strcpy(buffer, data)  # ← New vulnerability pattern
    return buffer
```

**Output**: `function_diff` set contains function identifiers with new CodeQL findings.

#### 2. Boundary Diff

**Purpose**: Identify functions that **became reachable** from entry points after the change.

**Analyzer**: [boundaryAnalyzer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/boundaryAnalyzer.py)

**Method** ([boundaryAnalyzer.py L55-73](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/boundaryAnalyzer.py#L55-L73)):
1. Identify reachable functions (from entry points) in before version
2. Identify reachable functions in after version
3. Flag functions in after but NOT in before (newly exposed)

**Example**:
```c
// Before: helper() is private/static
static void helper() { ... }

// After: helper() is public (boundary change)
void helper() { ... }  // ← Now reachable from entry points
```

**Output**: `boundary_diff` set contains newly reachable function identifiers.

#### 3. File Diff

**Purpose**: Identify functions in **modified files**, validated by LLM for security relevance.

**Analyzer**: [fileAnalyzer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/fileAnalyzer.py)

**Method** ([fileAnalyzer.py L56-80](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/fileAnalyzer.py#L56-L80)):
1. Extract git diff between versions
2. Identify modified files
3. For each function in modified files:
   - Extract function code and diff context
   - Use LLM to assess security relevance of changes
4. Flag security-relevant changed functions

**LLM Validation**: The LLM analyzes whether the code change could introduce vulnerabilities (not just any change).

**Output**: `file_diff` set contains function identifiers in security-relevant modified files.

### Overlap Calculation

**Purpose**: Identify functions that appear in **multiple** diff categories (highest priority).

**Calculation** ([DiffguyReport](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py#L22-L28)):
```python
overlap = function_diff ∩ boundary_diff ∩ file_diff
union = function_diff ∪ boundary_diff ∪ file_diff
```

## Weight Assignment

### Category-Based Weights

The filter assigns weights based on which diff categories a function belongs to ([lines 74-109](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py#L74-L109)):

| Category | Weight | Metadata | Meaning |
|----------|--------|----------|---------|
| **Overlap** | **12.0** | `"diffguy_category": "overlap"` | In all 3 categories (function + boundary + file diff) |
| **Boundary + Function** | **7.0** | `"boundary_diff + function_diff"` | New vulnerability pattern AND newly reachable |
| **Boundary + File** | **6.0** | `"boundary_diff + file_diff"` | Newly reachable in modified file |
| **Function + File** | **4.0** | `"function_diff + file_diff"` | Vulnerability pattern changed in modified file |
| **Boundary Only** | **4.0** | `"boundary_diff"` | Function boundary shifted (became reachable) |
| **File Only** | **3.0** | `"file_diff"` | In modified file (LLM-validated) |
| **Function Only** | **2.0** | `"function_diff"` | Vulnerability pattern changed |

### Weight Rationale

**Overlap (12.0)**: Strongest signal
- Function has new vulnerability pattern (Function Diff)
- Function became reachable (Boundary Diff)
- Function is in modified file (File Diff)
- All three signals agree → highest confidence

**Boundary + Function (7.0)**: High priority
- New vulnerability that's now exploitable
- Previously unreachable vulnerable code is now exposed

**Boundary + File (6.0)**: Exposure change
- Modified code that's now reachable
- Potential for new vulnerabilities in newly exposed surface

**Function + File (4.0)**: Moderate signal
- Vulnerability pattern changed in modified code
- Confirmed by both CodeQL and file modification

**Single Categories (2.0-4.0)**: Weaker signals
- Only one dimension of evidence
- Still worth investigating but lower confidence

### Code Implementation

**Filter Logic** ([lines 74-109](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py#L74-L109)):

```python
def apply(self, code_blocks: List[CodeBlock]) -> List[FilterResult]:
    out = []
    for code_block in code_blocks:
        key = code_block.function_key
        weight = 0.0
        metadata = {}

        # Check categories in priority order
        if key in self.diff_guy_report.overlap:
            weight = 12.0
            metadata["diffguy_category"] = "overlap"

        elif key in self.diff_guy_report.boundary_diff and \
             key in self.diff_guy_report.function_diff:
            weight = 7.0
            metadata["diffguy_category"] = "boundary_diff + function_diff"

        # ... (other combinations)

        res = FilterResult(weight=weight, metadata=metadata)
        out.append(res)
    return out
```

## Report Format

### DiffguyReport Structure

**File**: `diffguy_report.json`

**Schema** ([lines 22-37](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py#L22-L37)):

```python
class DiffguyReport(BaseObject):
    function_diff: Set[FUNCTION_INDEX_KEY]
    boundary_diff: Set[FUNCTION_INDEX_KEY]
    file_diff: Set[FUNCTION_INDEX_KEY]
    overlap: Set[FUNCTION_INDEX_KEY]
    union: Set[FUNCTION_INDEX_KEY]
    heuristic: Set[FUNCTION_INDEX_KEY]  # Additional heuristics
```

### Example Report

```json
{
    "function_diff": [
        "/src/parser.c:parse_request:123",
        "/src/auth.c:validate_token:45"
    ],
    "boundary_diff": [
        "/src/parser.c:parse_request:123",
        "/src/utils.c:helper_function:89"
    ],
    "file_diff": [
        "/src/parser.c:parse_request:123",
        "/src/parser.c:validate_header:67"
    ],
    "overlap": [
        "/src/parser.c:parse_request:123"
    ],
    "union": [
        "/src/parser.c:parse_request:123",
        "/src/parser.c:validate_header:67",
        "/src/auth.c:validate_token:45",
        "/src/utils.c:helper_function:89"
    ]
}
```

**Interpretation**:
- `parse_request`: In all 3 categories → weight = 12.0 (overlap)
- `validate_header`: Only in file_diff → weight = 3.0
- `validate_token`: Only in function_diff → weight = 2.0
- `helper_function`: Only in boundary_diff → weight = 4.0

## Use Cases

### 1. Patch Analysis

**Scenario**: Security patch review

**Workflow**:
```
Security Patch Applied
    ↓
DiffGuy analyzes before/after
    ↓
Identifies 5 functions in overlap category
    ↓
CodeSwipe prioritizes these with weight=12.0 each
    ↓
Discovery Guy generates PoCs for these functions first
```

**Benefit**: Focuses limited resources on highest-risk changed functions.

### 2. Continuous Integration

**Scenario**: Automated security analysis on pull requests

**Workflow**:
```
Developer submits PR
    ↓
CI runs DiffGuy on PR diff
    ↓
Functions with weight > 10.0 flagged for manual review
    ↓
Prevents merging high-risk changes without security review
```

### 3. Regression Testing

**Scenario**: Verify patch didn't introduce new vulnerabilities

**Workflow**:
```
Patch applied to fix CVE-2024-12345
    ↓
DiffGuy detects 2 functions in boundary_diff
    ↓
Fuzzers target these newly reachable functions
    ↓
Detect regression (patch introduced new bug)
```

## Delta Mode vs Full Mode

### Delta Mode (DiffGuy Active)

**Trigger**: `--diffguy-report-dir` argument provided

**Filter Registration** ([main.py L273-275](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L273-L275)):
```python
if self.args.diffguy_report_dir:
    filters += [DiffguyFilter.from_report(self.args.diffguy_report_dir)]
```

**Characteristics**:
- Focus on changed functions
- Higher weights for modified code (up to 12.0)
- Fast analysis (only analyze diff, not entire codebase)

### Full Mode (DiffGuy Disabled)

**Trigger**: No diffguy report provided

**Characteristics**:
- Analyze entire codebase uniformly
- No bonus for changed functions
- Slower but comprehensive

## Performance Characteristics

### DiffGuy Component (Preprocessing)

**Complexity**:
- **Function Diff**: O(F × Q) where F = functions, Q = CodeQL queries
- **Boundary Diff**: O(V + E) call graph traversal
- **File Diff**: O(F_modified × LLM_latency) - most expensive

**Typical Runtime**: Minutes to hours depending on:
- Size of diff (number of modified files)
- Number of functions in modified files
- LLM API rate limits

### DiffGuy Filter (CodeSwipe)

**Complexity**: O(N) where N = total functions (simple set membership check)

**Typical Runtime**: < 1 second (fast lookup in pre-computed sets)

## Limitations

### 1. Requires Before/After Versions

**Problem**: DiffGuy needs both versions of the codebase.

**Not Applicable**:
- Initial codebase analysis (no "before" version)
- Lost history (old version not available)

**Mitigation**: Fall back to Full Mode.

### 2. LLM Dependency for File Diff

**Problem**: File Diff analyzer uses LLM for validation ([fileAnalyzer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/fileAnalyzer.py)).

**Challenges**:
- **Cost**: LLM API calls for every function in modified files
- **Rate Limits**: May require throttling
- **Accuracy**: LLM may have false positives/negatives

**Mitigation** ([fileAnalyzer.py L43-54](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/fileAnalyzer.py#L43-L54)):
- Nap/retry logic for rate limits
- Timeout handling (120s per function)
- Max functions limit (configurable)

### 3. Function Resolution

**Problem**: Function identifiers from diff may not match function index keys.

**Challenge**: Path differences between repositories (e.g., `/src/foo.c` vs `./foo.c`)

**Solution** ([diffguy.py L47-64](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py#L47-L64)):
```python
# Load report
report = DiffguyReport(**report_data)

# Sanitize (remove empty strings)
report.sanitize()
```

**FunctionResolver**: Used in analyzers to normalize identifiers.

## Configuration

### DiffGuy Component Configuration

**File**: [config.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/config.py)

**Key Settings**:
```python
MAX_FUNCTIONS_IN_FILE_DIFF = 100  # Limit LLM analysis
DIFFGUY_TIMEOUT = 120              # Seconds per function
NAP_DURATION = 15                   # Minutes to wait on rate limit
```

### DiffGuy Filter Configuration

**Filter Name**: `diffguy` ([line 41](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py#L41))

**Enabled When**: DiffGuy report directory provided

**Loading** ([lines 47-64](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py#L47-L64)):
```python
@classmethod
def from_report(cls, report_dir: Path) -> "DiffguyFilter":
    report_files = list(report_dir.glob("**/diffguy_report.json"))
    if not report_files:
        raise ValueError(f"No diffguy report found in {report_dir}")

    report_path = report_files[0]
    with open(report_path, "r") as f:
        report = json.load(f)

    return cls(diff_guy_report=DiffguyReport(**report))
```

## Integration in CodeSwipe Pipeline

**Position**: **First filter** (highest priority for delta mode)

**Filter Order** ([main.py L273-275](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L273-L275)):
```python
filters = [
    DiffguyFilter,  # ← First (delta mode only)
    SemgrepFilter,
    CodeQLFilter,
    ScanGuyFilter,
    SimpleReachabilityFilter,
    DangerousFunctionsFilter,
    DynamicReachabilityFilter,
    SkipTestsFilter
]
```

**Rationale for Position**:
- Provides early high-weight signal for changed functions
- Subsequent filters add complementary signals
- Delta mode prioritizes speed (changed functions first)

## Output Format

**In CodeSwipeRanking YAML**:

```yaml
ranking:
  - function_index_key: "/src/parser.c:parse_request:123"
    priority_score: 42.0
    weights:
      diffguy: 12.0  # ← Overlap category
      semgrep: 10.0
      codeql: 8.0
      dangerous_functions: 8.0
      simple_reachability: 1.0
      dynamic_reachability: 1.0
    metadata:
      diffguy_category: "overlap"  # ← Metadata shows why
      semgrep: ["buffer-overflow"]
      codeql: ["uaf"]
```

## Comparison: DiffGuy vs Other Filters

| Aspect | DiffGuy | Semgrep/CodeQL | Dangerous Functions |
|--------|---------|----------------|---------------------|
| **Scope** | Changed functions only | All functions | All functions |
| **Basis** | Differential analysis | Pattern/dataflow | API calls |
| **Mode** | Delta mode only | Both modes | Both modes |
| **Weight Range** | 2.0 - 12.0 | 2.0 - 23.0 | 0.1 - 8.0 |
| **Preprocessing** | Separate component | Standalone tools | Built-in |
| **Performance** | Medium (LLM for file diff) | Medium (static analysis) | Fast (pattern matching) |

## Related Documentation

- **[CodeSwipe Overview](codeswipe-overview.md)** - Filter framework
- **[Weight System](weights.md)** - Weight aggregation and rationale
- **[CodeQL Queries](codeql-queries.md)** - Used by Function Diff analyzer
- **[Preprocessing](../preprocessing/readme.md)** - Function indexing and call graphs

## References

- **Filter Implementation**: [diffguy.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/diffguy.py)
- **DiffGuy Component**: [components/diffguy/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/diffguy)
- **Analyzers**:
  - [funcAnalyzer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/funcAnalyzer.py)
  - [boundaryAnalyzer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/boundaryAnalyzer.py)
  - [fileAnalyzer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/diffguy/core/analyzer/fileAnalyzer.py)
- **Integration**: [main.py L273-279](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L273-L279)
