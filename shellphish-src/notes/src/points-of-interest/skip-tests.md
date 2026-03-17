# Skip Tests Filter

## Overview

The **Skip Tests Filter** identifies and marks test files and test functions to exclude them from vulnerability analysis. This filter ensures that POI ranking focuses on production code rather than test harnesses, preventing wasted resources on non-production code.

**Purpose**: Automatically detect and exclude test code from POI prioritization.

**Location**: [skip_tests.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/skip_tests.py)

## How It Works

### Detection Heuristics

The filter uses **path-based heuristics** to identify test code ([lines 25-33](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/skip_tests.py#L25-L33)):

```python
filepath = Path(block.function_info.focus_repo_relative_path)

filename = filepath.name.lower()       # e.g., "test_parser.c"
parent_dir = filepath.parent.name.lower()  # e.g., "tests"
file_stem = filepath.stem.lower()      # e.g., "test_parser" from "test_parser.c"
```

### Test Detection Rules

**Rule 1: Test Directory Names** ([line 12](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/skip_tests.py#L12))
```python
__TEST_NAMES__ = {"test", "tests"}
```

**Rule 2: Test File Suffixes** ([line 13](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/skip_tests.py#L13))
```python
__TEST_SUFFIXES__ = ("test", "tests")
```

**Matching Logic** ([lines 31-35](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/skip_tests.py#L31-L35)):
```python
if filename in self.__TEST_NAMES__ or \
    parent_dir in self.__TEST_NAMES__ or \
    file_stem.endswith(self.__TEST_SUFFIXES__):

    metadata = {"is_test": True}
```

### Examples

#### Test Files (Detected)

| File Path | Matches Rule | Reason |
|-----------|-------------|--------|
| `tests/parser.c` | ✓ | Parent directory is "tests" |
| `test/utils.c` | ✓ | Parent directory is "test" |
| `src/test_parser.c` | ✓ | File stem ends with "test" |
| `src/parser_tests.c` | ✓ | File stem ends with "tests" |
| `test.c` | ✓ | Filename is "test" |
| `tests.cpp` | ✓ | Filename is "tests" |

#### Production Files (Not Detected)

| File Path | Detected? | Reason |
|-----------|-----------|--------|
| `src/parser.c` | ✗ | No test-related path components |
| `src/testing_utils.c` | ✗ | Contains "test" but doesn't end with it |
| `src/attest.c` | ✗ | "test" is substring but doesn't match pattern |

## Filter Application

**Method**: `apply()` ([lines 15-41](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/skip_tests.py#L15-L41))

For each code block:

```python
def apply(self, code_blocks: List[CodeBlock]) -> List[FilterResult]:
    results = []

    for block in code_blocks:
        weight = 0.0  # Always 0.0 (this filter doesn't boost priority)
        metadata = {"is_test": False}  # Default: not a test

        # ... detection logic ...

        if is_test:
            metadata = {"is_test": True}

        result = FilterResult(weight=weight, metadata={"skip_test": metadata})
        results.append(result)

    return results
```

## Weight Assignment

| Condition | Weight | Metadata |
|-----------|--------|----------|
| Test file detected | **0.0** | `{"skip_test": {"is_test": True}}` |
| Production file | **0.0** | `{"skip_test": {"is_test": False}}` |

**Important**: This filter **never assigns positive weights**. Its role is purely to mark test files via metadata.

## Downstream Impact

### Priority Score Zeroing

The real impact happens during **priority score calculation** in the filter framework ([filter_framework.py L139-142](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/framework/filter_framework.py#L139-L142)):

```python
for result in block.filter_results.values():
    if result.metadata.get("is_test", False):
        should_skip = True
        break  # No need to process further results

if should_skip:
    block.priority_score = 0.0  # Override ALL other weights
```

**Effect**: If ANY filter marks a code block with `{"is_test": True}`, the entire block gets `priority_score = 0.0` regardless of other filter weights.

### Example

**Before Skip Tests Filter**:
```yaml
function_index_key: "tests/test_parser.c:test_overflow:42"
weights:
  semgrep: 10.0
  codeql: 8.0
  dangerous_functions: 4.0
  simple_reachability: 1.0
priority_score: 23.0  # Sum of all weights
```

**After Skip Tests Filter**:
```yaml
function_index_key: "tests/test_parser.c:test_overflow:42"
weights:
  semgrep: 10.0
  codeql: 8.0
  dangerous_functions: 4.0
  simple_reachability: 1.0
  skip_tests_filter: 0.0
metadata:
  skip_test:
    is_test: true  # ← Triggers zeroing
priority_score: 0.0  # ← Zeroed out
```

**Result**: This function will be ranked last (or filtered out) in the final output.

## Rationale

### Why Skip Test Code?

1. **Resource Efficiency**: Test code is intentionally written to trigger edge cases and vulnerabilities—analyzing it wastes fuzzing/PoC generation resources.

2. **False Positives**: Test files often contain:
   - Intentionally vulnerable code samples
   - Mock implementations with unsafe patterns
   - Synthetic test cases for vulnerability detectors

3. **Production Focus**: Security analysis should target production code that will be deployed, not test harnesses.

### Why Not Delete from Code Blocks?

**Design Choice**: Rather than filtering out test files entirely, the system:
- Marks them with metadata
- Zeros their priority score
- Keeps them in the ranking (at the bottom)

**Benefits**:
- Visibility: Shows that test files were considered
- Debugging: Can verify filter is working correctly
- Flexibility: Downstream components can choose to handle tests differently

## Limitations

### 1. Path-Based Heuristics Only

**Problem**: The filter only uses path patterns, not code analysis.

**Missed Cases**:
```c
// In src/utils.c (not detected as test)
#ifdef UNIT_TEST
void test_helper_function() {
    // Actually a test function, but not in test directory
}
#endif
```

**Impact**: Test functions embedded in production files may not be detected.

### 2. Language-Agnostic Patterns

**Problem**: Uses generic patterns that may miss language-specific test conventions.

**Examples**:
- **Java**: JUnit tests with `@Test` annotations (not detected by path alone)
- **Python**: `pytest` fixtures and test classes (may not follow naming convention)
- **Rust**: `#[test]` attribute (requires code parsing)

**Potential Enhancement**: Add language-specific detection logic.

### 3. False Positives

**Problem**: Files with "test" in the name that aren't tests.

**Examples**:
- `attestation.c` (legitimate production code)
- `contest.c` (legitimate production code)
- `protest_handler.c` (legitimate production code)

**Mitigation**: The current implementation uses `endswith()` rather than `contains()` to reduce false positives ([line 33](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/skip_tests.py#L33)):

```python
file_stem.endswith(self.__TEST_SUFFIXES__)  # "test_parser" ✓, "attest" ✗
```

## Configuration

**Filter Name**: `skip_tests_filter` ([line 9](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/skip_tests.py#L9))

**Enabled by Default**: Yes ([line 10](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/skip_tests.py#L10))

**Configurable Patterns**:
```python
__TEST_NAMES__ = {"test", "tests"}          # Line 12
__TEST_SUFFIXES__ = ("test", "tests")       # Line 13
```

**Customization**: To add more patterns, modify these class variables (e.g., add "spec" for RSpec tests).

## Integration in CodeSwipe Pipeline

**Position**: **Last filter** in the pipeline

**Filter Order** ([main.py L382-383](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L382-L383)):
```python
filters = [
    DiffguyFilter,
    SemgrepFilter,
    CodeQLFilter,
    ScanGuyFilter,
    SimpleReachabilityFilter,
    DangerousFunctionsFilter,
    DynamicReachabilityFilter,
    SkipTestsFilter  # ← Last filter
]
```

**Rationale for Position**:
- Runs after all other filters (so they don't waste time on production-specific analysis)
- Metadata is checked during priority score calculation (after all filters run)
- Order doesn't affect functionality (since it's a metadata-only filter)

## Use Cases

### 1. Fuzzing Resource Allocation

**Problem**: Fuzzing test harnesses wastes CPU cycles on non-production code.

**Solution**: Skip Tests Filter ensures test code gets `priority_score = 0.0`, preventing fuzzers from targeting it.

### 2. PoC Generation

**Problem**: Generating exploits for intentionally vulnerable test code is meaningless.

**Solution**: Discovery Guy skips functions with `priority_score = 0.0`.

### 3. Vulnerability Reporting

**Problem**: Reporting vulnerabilities in test code creates false alarms.

**Solution**: Final reports can filter out test files based on `is_test` metadata.

## Output Format

**In CodeSwipeRanking YAML**:

```yaml
ranking:
  # Production code (high priority)
  - function_index_key: "src/parser.c:parse_input:42"
    priority_score: 25.0
    metadata:
      skip_test:
        is_test: false

  # Test code (zeroed priority)
  - function_index_key: "tests/test_parser.c:test_overflow:123"
    priority_score: 0.0  # ← Zeroed out
    metadata:
      skip_test:
        is_test: true  # ← Marked as test
```

**Sorting Effect**: Test files appear at the bottom of the ranking (sorted by `priority_score`).

## Future Enhancements

### 1. Code-Level Detection

**Proposal**: Add AST-based detection for test functions.

**Example** (Java):
```java
@Test
public void testParserOverflow() {  // Detected via @Test annotation
    // ...
}
```

**Implementation**: Extend filter to parse annotations/attributes during preprocessing.

### 2. Configurable Patterns

**Proposal**: Allow users to specify custom test patterns via configuration.

**Example**:
```yaml
skip_tests_config:
  test_directories: ["test", "tests", "spec", "__tests__"]
  test_suffixes: ["test", "tests", "spec"]
  test_prefixes: ["test_", "spec_"]
```

### 3. Negative Weight Option

**Proposal**: Instead of zeroing, allow negative weights to penalize test code.

**Benefit**: Provides more gradual deprioritization rather than hard cutoff.

## Related Documentation

- **[CodeSwipe Overview](codeswipe-overview.md)** - Filter framework and priority score calculation
- **[Weight System](weights.md)** - How `is_test` metadata affects aggregation
- **[Filter Framework](codeswipe-overview.md#filter-framework)** - Priority score zeroing logic

## References

- **Implementation**: [skip_tests.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/skip_tests.py)
- **Integration**: [main.py L382-383](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L382-L383)
- **Priority Zeroing**: [filter_framework.py L139-149](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/framework/filter_framework.py#L139-L149)
