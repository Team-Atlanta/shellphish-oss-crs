# Dangerous Functions Filter

## Overview

The **Dangerous Functions Filter** identifies functions that call unsafe C/C++ APIs or contain risky code structures (loops, conditional branches) that are commonly associated with vulnerabilities. This is a fast, pattern-based heuristic filter that doesn't require external tools.

**Purpose**: Boost priority of functions calling memory-unsafe APIs or containing complex control flow.

**Location**: [dangerous_functions.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py)

## How It Works

### 1. Dangerous Function Detection

**Source Data**: `code_block.function_info.func_calls_in_func_with_fullname`

This field (populated during preprocessing) contains the list of all function calls within a given function.

**Matching Logic** ([lines 58-67](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L58-L67)):

```python
for dangerous_function in self.__DANGEROUS_FUNCTIONS__.get(self.language, {}):
    if dangerous_function in code_block.function_info.func_calls_in_func_with_fullname:
        weight += self.__DANGEROUS_FUNCTIONS__[self.language][dangerous_function]

        # Track which dangerous functions were found
        metadata["potentially_dangerous_functions"].append(dangerous_function)
```

### 2. Dangerous Code Structure Detection

**Source Data**: `code_block.function_info.code.lower()`

The actual source code of the function (lowercased for case-insensitive matching).

**Matching Logic** ([lines 69-80](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L69-L80)):

```python
code = code_block.function_info.code.lower()

for dangerous_code_structure in self.__DANGEROUS_CODE_STRUCTURES__.get(self.language, {}):
    if dangerous_code_structure in code:
        weight += self.__DANGEROUS_CODE_STRUCTURES__[self.language][dangerous_code_structure]

        # Track which structures were found
        metadata["potentially_dangerous_code"].append(dangerous_code_structure)
```

## Weight Tables

### Dangerous Functions (C/C++)

**Location**: [Lines 14-34](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L14-L34)

| Function | Weight | Risk Category | Reason |
|----------|--------|---------------|--------|
| `gets` | **8.0** | Critical | Unbounded buffer read, always unsafe |
| `strcpy` | **8.0** | Critical | No bounds checking, buffer overflow |
| `system` | **8.0** | Critical | Command injection risk |
| `strcat` | **4.0** | High | Potential buffer overflow |
| `exec` | **4.0** | High | Code execution risk (exec family) |
| `free` | **1.5** | Medium | Memory management, potential double-free/UAF |
| `fgets` | **0.5** | Low | Safer than gets, but noteworthy |
| `memcpy` | **0.1** | Very Low | Common, context-dependent |

**Language Support**: Same weights for both C and C++ ([lines 15-34](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous-functions.py#L15-L34))

### Dangerous Code Structures (C/C++)

**Location**: [Lines 36-48](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L36-L48)

| Pattern | Weight | Risk Category | Reason |
|---------|--------|---------------|--------|
| `for ` | **0.5** | Low | Loop iteration (off-by-one errors) |
| `for(` | **0.5** | Low | Loop iteration (off-by-one errors) |
| `while ` | **0.3** | Very Low | Loop iteration |
| `while(` | **0.3** | Very Low | Loop iteration |

**Rationale**: Loops increase complexity and are common sources of:
- Off-by-one errors
- Infinite loops
- Buffer overflow during iteration

## Weight Calculation

### Additive Scoring

Weights are **summed** across all matches ([lines 64, 80](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L64)):

```python
weight += self.__DANGEROUS_FUNCTIONS__[language][dangerous_function]
# AND
weight += self.__DANGEROUS_CODE_STRUCTURES__[language][dangerous_code_structure]
```

**Example 1**: Function calling `strcpy` and `system`
```
strcpy: 8.0
system: 8.0
────────────
Total: 16.0
```

**Example 2**: Function with `gets`, two `for` loops, and one `while` loop
```
gets:     8.0
for (×2):  1.0  (0.5 × 2)
while:    0.3
────────────
Total:    9.3
```

### Multiple Occurrences

**Loops**: Each occurrence is counted separately (simple substring search)

```c
void process_data(char* input) {
    char buf[100];
    strcpy(buf, input);  // +8.0

    for (int i = 0; i < 100; i++) {  // +0.5 (first "for ")
        for (int j = 0; j < 100; j++) {  // +0.5 (second "for(")
            // ...
        }
    }
}
// Total: 8.0 + 0.5 + 0.5 = 9.0
```

**Function Calls**: Only counted once per unique function name (based on call list, not string search)

## Metadata Output

### Structure

```python
{
    "potentially_dangerous_functions": ["strcpy", "system"],
    "potentially_dangerous_code": ["for ", "while "]
}
```

### Example

**Code**:
```c
void parse_request(char* input) {
    char buffer[256];
    strcpy(buffer, input);

    for (int i = 0; i < strlen(input); i++) {
        if (buffer[i] == '\0') break;
    }
}
```

**Filter Result**:
```python
FilterResult(
    weight=8.5,  # strcpy (8.0) + for (0.5)
    metadata={
        "potentially_dangerous_functions": ["strcpy"],
        "potentially_dangerous_code": ["for "]
    }
)
```

## Language Support

**Current Languages**: C and C++ ([lines 14-48](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L14-L48))

**Language Selection** ([line 12](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L12)):
```python
language: str = "c"  # Set during filter initialization
```

**Lookup** ([line 58](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L58)):
```python
self.__DANGEROUS_FUNCTIONS__.get(self.language, {})
```

**Extensibility**: To add Java or Python support, extend the dictionaries with new language keys:

```python
__DANGEROUS_FUNCTIONS__ = {
    'c': {...},
    'c++': {...},
    'java': {
        "Runtime.exec": 8.0,
        "ProcessBuilder": 4.0,
        # ...
    }
}
```

## Rationale for Weights

### High Weights (8.0)

**Functions**: `gets`, `strcpy`, `system`

**Reasoning**:
- **No safe usage pattern**: These functions are inherently unsafe
- **CWE associations**: Directly linked to common CVEs
  - `gets`: CWE-120 (Buffer Copy without Checking Size of Input)
  - `strcpy`: CWE-120
  - `system`: CWE-78 (OS Command Injection)
- **Exploit likelihood**: High probability of exploitation

### Medium Weights (4.0)

**Functions**: `strcat`, `exec`

**Reasoning**:
- **Context-dependent**: Can be used safely with proper bounds checking
- **Common in legacy code**: Widely used but requires careful handling
- **Moderate exploit likelihood**: Exploitable but less common than high-weight functions

### Low Weights (0.5-1.5)

**Functions**: `free`, `fgets`, `memcpy`

**Reasoning**:
- **`free`**: Correct usage is safe, but memory management bugs (double-free, UAF) are common
- **`fgets`**: Safe alternative to `gets`, but still worth noting
- **`memcpy`**: Ubiquitous, only dangerous with incorrect size calculation

### Minimal Weights (0.3-0.5)

**Code Structures**: Loops

**Reasoning**:
- **Weak signal**: Most loops are benign
- **Complexity indicator**: More complex code has higher bug potential
- **Common patterns**: Too common to assign high weight without overwhelming other signals

## Limitations

### 1. No Context Awareness

**Problem**: Cannot distinguish safe vs unsafe usage.

**False Positive Example**:
```c
void safe_copy(char* dest, const char* src, size_t dest_size) {
    // Actually safe - bounds checked
    if (strlen(src) < dest_size) {
        strcpy(dest, src);  // Still flagged +8.0
    }
}
```

**Impact**: May over-prioritize properly validated code.

### 2. Simple String Matching for Loops

**Problem**: Substring search counts loops in comments or strings.

**False Positive Example**:
```c
void foo() {
    // Comment: "for debugging purposes"  ← Counted as +0.5
    char msg[] = "for the user";           ← Counted as +0.5
}
```

**Impact**: Inflates weight for functions with certain keywords in comments/strings.

### 3. Missing Modern Unsafe Patterns

**Problem**: Focused on classic C vulnerabilities, missing newer patterns.

**Examples Not Covered**:
- **C++**: `std::copy` with unchecked iterators
- **Concurrency**: Race conditions, TOCTOU bugs
- **Integer overflows**: Arithmetic on size calculations

**Future Enhancement**: Extend tables to cover broader vulnerability classes.

### 4. Language Coverage

**Current**: Only C/C++

**Missing**:
- **Java**: Deserialization, JNDI injection
- **Python**: `eval`, `exec`, `pickle`
- **JavaScript**: `eval`, `innerHTML`, `dangerouslySetInnerHTML`

## Use Cases

### 1. Fast Pre-Filtering

**Scenario**: Quick triage before expensive analysis.

**Workflow**:
```
All Functions (10,000)
    ↓
Dangerous Functions Filter (fast pattern matching)
    ↓
Functions with unsafe APIs (1,000) → Prioritized for Semgrep/CodeQL
```

### 2. Complement to Static Analysis

**Pattern**: Dangerous Functions catches low-hanging fruit that may slip through query-based tools.

**Example**: Semgrep may miss simple `strcpy` calls if the rule is too specific, but this filter will always catch it.

### 3. Baseline Signal

**Role**: Provides a **minimum viable signal** when other filters (Semgrep, CodeQL) have no findings.

**Example**:
```yaml
function_index_key: "utils.c:copy_string:89"
weights:
  semgrep: 0         # No rule match
  codeql: 0          # No query match
  dangerous_functions: 8.0  # ← Only signal
priority_score: 8.0  # Still ranked higher than 0-weight functions
```

## Performance Characteristics

### Speed

**Fast**: Simple dictionary lookups and substring searches.

**Time Complexity**:
- Function matching: O(F × D) where F = functions called, D = dangerous functions table size
- Code structure matching: O(C × S) where C = code length, S = number of structure patterns

**Typical Runtime**: < 1ms per function

### Memory

**Minimal**: Only stores metadata lists for matched patterns.

## Configuration

**Filter Name**: `dangerous_functions` ([line 8](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L8))

**Enabled by Default**: Yes ([line 9](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L9))

**Language Configuration** ([line 12](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py#L12)):
```python
language: str = "c"  # Set during initialization
```

**Initialization** ([main.py L366-367](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L366-L367)):
```python
DangerousFunctionsFilter(language=self.project.project_language)
```

## Integration in CodeSwipe Pipeline

**Position**: Mid-pipeline (after expensive filters, before reachability)

**Filter Order** ([main.py L366-367](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L366-L367)):
```python
filters = [
    DiffguyFilter,
    SemgrepFilter,
    CodeQLFilter,
    ScanGuyFilter,
    SimpleReachabilityFilter,
    DangerousFunctionsFilter,  # ← After static analysis, before dynamic
    DynamicReachabilityFilter,
    SkipTestsFilter
]
```

**Rationale for Position**:
- After expensive filters (Semgrep, CodeQL, LLM) which provide richer signals
- Before reachability filters which provide metadata-only signals
- Fast execution means position is flexible

## Output Format

**In CodeSwipeRanking YAML**:

```yaml
ranking:
  - function_index_key: "parser.c:parse_input:42"
    priority_score: 33.0
    weights:
      semgrep: 10.0
      codeql: 8.0
      dangerous_functions: 8.5  # ← strcpy (8.0) + for (0.5)
      simple_reachability: 1.0
      dynamic_reachability: 1.0
    metadata:
      potentially_dangerous_functions: ["strcpy"]
      potentially_dangerous_code: ["for "]
      semgrep: ["buffer-overflow"]
```

## Customization Guide

### Adding New Dangerous Functions

**Example**: Add `sprintf` as a dangerous function

```python
__DANGEROUS_FUNCTIONS__ = {
    'c': {
        "gets": 8.0,
        "strcpy": 8.0,
        "system": 8.0,
        "sprintf": 6.0,  # ← New entry
        # ...
    }
}
```

### Adding Language Support

**Example**: Add Python dangerous functions

```python
__DANGEROUS_FUNCTIONS__ = {
    'c': {...},
    'c++': {...},
    'python': {
        "eval": 8.0,
        "exec": 8.0,
        "pickle.loads": 6.0,
        "subprocess.call": 4.0,
    }
}

__DANGEROUS_CODE_STRUCTURES__ = {
    'python': {
        "import os": 0.5,
        "import subprocess": 0.5,
    }
}
```

### Adjusting Weights

**Strategy**: Tune weights based on historical vulnerability data.

**Example**: If `free`-related bugs are common in your codebase:

```python
"free": 4.0,  # Increased from 1.5
```

## Related Documentation

- **[CodeSwipe Overview](codeswipe-overview.md)** - Filter framework
- **[Weight System](weights.md)** - Weight aggregation and rationale
- **[Semgrep Rules](semgrep-rules.md)** - Complementary pattern-based analysis
- **[Preprocessing](../preprocessing/indexer.md)** - Function call extraction

## References

- **Implementation**: [dangerous_functions.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dangerous_functions.py)
- **Integration**: [main.py L366-367](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L366-L367)
- **CWE References**:
  - [CWE-120: Buffer Copy without Checking Size of Input](https://cwe.mitre.org/data/definitions/120.html)
  - [CWE-78: OS Command Injection](https://cwe.mitre.org/data/definitions/78.html)
