# Static Reachability Filter

## Overview

The **Static Reachability Filter** identifies functions that are reachable from program entry points (harness entry points) via static call graph analysis. This filter helps prioritize functions that can actually be executed, filtering out dead code and unreachable functions.

**Purpose**: Boost the priority of functions that are callable from fuzzing harnesses, ensuring analysis resources focus on executable code paths.

**Location**: [static_reachability.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/static_reachability.py)

## How It Works

### 1. Reachability Computation

**Class**: `ReachabilityComputer` ([lines 13-43](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/static_reachability.py#L13-L43))

**Algorithm**: Depth-first search (DFS) through the call graph

```python
def _locate_reachable_blocks(self, code_block: CodeBlock, call_stack: List[str]=[]) -> None:
    if code_block.unique_id in self.reachable_blocks:
        return  # Already visited

    self.reachable_blocks[code_block.unique_id] = code_block

    # Recursively traverse callees
    for call in code_block.func_calls_in_func_with_fullname:
        func_blocks = self.code_registry.find_function_by_name(call)
        for func_block in func_blocks:
            self._locate_reachable_blocks(func_block, call_stack)
```

**Starting Points**: Entry points from fuzzing harnesses ([line 55](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/static_reachability.py#L55))
```python
roots=code_registry.entrypoint_code_blocks
```

### 2. Preprocessing Phase

**Method**: `pre_process_project()` ([lines 52-63](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/static_reachability.py#L52-L63))

This runs **before** filter application to build the reachability map:

```python
def pre_process_project(self, project: OSSFuzzProject, code_registry: CodeRegistry, metadata: Dict[str, Any]) -> None:
    # Create reachability computer
    self.reachability_computer = ReachabilityComputer(
        code_registry=code_registry,
        roots=code_registry.entrypoint_code_blocks
    )

    # Compute all reachable functions
    self.reachability_computer.locate_all_reachable_blocks()
```

### 3. Filter Application

**Method**: `apply()` ([lines 65-79](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/static_reachability.py#L65-L79))

For each code block:

```python
def apply(self, code_blocks: List[CodeBlock]) -> List[FilterResult]:
    out = []
    for code_block in code_blocks:
        if self.reachability_computer.is_reachable(code_block):
            res = FilterResult(
                weight=1.0,
                metadata={"reachable": True}
            )
        else:
            res = FilterResult(weight=0.0)
        out.append(res)
    return out
```

## Weight Assignment

| Condition | Weight | Metadata |
|-----------|--------|----------|
| Function is reachable from entry points | **1.0** | `{"reachable": True}` |
| Function is NOT reachable | **0.0** | `{}` |

**Rationale**: Binary signal (reachable vs unreachable) with small positive weight to slightly boost reachable functions.

## Call Graph Dependency

The filter relies on **function call information** extracted during preprocessing:

**Call Information Source**: `code_block.func_calls_in_func_with_fullname` ([line 40](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/static_reachability.py#L40))

This field comes from the **Function Indexer** which parses the AST to extract function calls.

## Entry Points

Entry points are typically:
- **Fuzzing harness entry functions** (e.g., `LLVMFuzzerTestOneInput`)
- **Main functions** in test programs
- **Public API entry points** defined in the code registry

These are identified during the preprocessing phase and stored in `code_registry.entrypoint_code_blocks`.

## Example

### Call Graph

```
LLVMFuzzerTestOneInput (ENTRY POINT)
  ├─> parse_input()
  │     ├─> validate_header()
  │     └─> process_body()
  │           └─> decode_data()
  └─> cleanup()

orphan_function()  // Not reachable
```

### Filter Results

| Function | Reachable? | Weight | Metadata |
|----------|-----------|--------|----------|
| `LLVMFuzzerTestOneInput` | ✓ | 1.0 | `{"reachable": True}` |
| `parse_input` | ✓ | 1.0 | `{"reachable": True}` |
| `validate_header` | ✓ | 1.0 | `{"reachable": True}` |
| `process_body` | ✓ | 1.0 | `{"reachable": True}` |
| `decode_data` | ✓ | 1.0 | `{"reachable": True}` |
| `cleanup` | ✓ | 1.0 | `{"reachable": True}` |
| `orphan_function` | ✗ | 0.0 | `{}` |

## Limitations

### 1. Virtual Functions (C++)

Static analysis may miss calls through virtual function tables:

```cpp
class Base {
    virtual void process() = 0;
};

void harness(Base* obj) {
    obj->process();  // Which implementation? Unknown at compile-time
}
```

**Impact**: Some reachable functions may be marked as unreachable.

### 2. Function Pointers

Indirect calls via function pointers may not be tracked:

```c
void (*handler)(void*) = get_handler();
handler(data);  // Target unknown statically
```

**Mitigation**: Use [Dynamic Reachability Filter](dynamic-reachability.md) to capture runtime-verified reachability.

### 3. Dynamic Linking

Functions called via `dlopen()` and `dlsym()` are not tracked:

```c
void* handle = dlopen("libfoo.so", RTLD_LAZY);
void (*func)() = dlsym(handle, "bar");
func();  // Dynamically resolved
```

## Use Cases

### 1. Pre-filtering for Expensive Filters

**Pattern**: Run static reachability first, then only apply expensive filters (LLM-based analysis) to reachable functions.

**Example**:
```python
# In LLuMinar filter
def apply(self, code_blocks):
    for block in code_blocks:
        # Skip unreachable functions to save LLM API calls
        if not block.filter_results.get("simple_reachability", {}).metadata.get("reachable"):
            continue

        # Run expensive LLM analysis only on reachable functions
        result = llm_analyze(block)
```

### 2. Fuzzing Instrumentation Targeting

**Downstream Consumer**: AIJON (fuzzing instrumentation)

**Usage**: Only instrument reachable functions for coverage-guided fuzzing

```python
# In AIJON
for poi in pois:
    if poi["metadata"].get("reachable"):
        instrument_function(poi["function_index_key"])
```

### 3. Dead Code Detection

**Pattern**: Functions with `weight=0.0` from static reachability are potential dead code.

**Use Case**: Security auditors can deprioritize or ignore unreachable code.

## Comparison: Static vs Dynamic Reachability

| Aspect | Static Reachability | [Dynamic Reachability](dynamic-reachability.md) |
|--------|---------------------|------------------------------------------------|
| **Basis** | Call graph analysis | Runtime coverage data |
| **Coverage** | May over-approximate (include unreachable via virtual calls) | Under-approximates (only covered paths) |
| **Speed** | Fast (one-time graph traversal) | Depends on fuzzing coverage |
| **Accuracy** | May have false positives | High precision (actually executed) |
| **Metadata** | Simple boolean | Includes harness name / grammar |
| **Use Case** | Pre-filtering, dead code detection | Targeted fuzzing, harness selection |

## Performance Characteristics

**Time Complexity**: O(V + E) where:
- V = number of functions (vertices)
- E = number of function calls (edges)

**Space Complexity**: O(V) for storing the reachable set

**Optimization**: Memoization via `self.reachable_blocks` prevents redundant traversals ([line 32](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/static_reachability.py#L32))

## Integration in CodeSwipe Pipeline

**Position**: Mid-pipeline (after static analysis, before expensive filters)

**Filter Order** ([main.py L358-359](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L358-L359)):
```python
filters = [
    DiffguyFilter,           # Delta mode
    SemgrepFilter,           # Pattern matching
    CodeQLFilter,            # Dataflow analysis
    ScanGuyFilter,           # LLM analysis (expensive)
    SimpleReachabilityFilter,  # ← Static reachability
    DangerousFunctionsFilter,
    DynamicReachabilityFilter,
    SkipTestsFilter
]
```

**Rationale for Position**:
- After static analysis (Semgrep, CodeQL) which doesn't need reachability info
- Before/alongside expensive filters which can use reachability to optimize
- Provides metadata for downstream filters

## Configuration

**Filter Name**: `simple_reachability` ([line 46](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/static_reachability.py#L46))

**Enabled by Default**: Yes ([line 47](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/static_reachability.py#L47))

**Configuration Options**: None (no configurable parameters)

## Output Format

**In CodeSwipeRanking YAML**:

```yaml
ranking:
  - function_index_key: "parser.c:parse_input:42"
    priority_score: 25.0
    weights:
      semgrep: 10.0
      codeql: 8.0
      simple_reachability: 1.0  # ← Contributes +1.0
      dangerous_functions: 6.0
    metadata:
      reachable: true  # ← Metadata from filter
      semgrep: ["buffer-overflow"]
      codeql: ["uaf"]
```

## Related Documentation

- **[Dynamic Reachability Filter](dynamic-reachability.md)** - Runtime-verified reachability
- **[CodeSwipe Overview](codeswipe-overview.md)** - Complete filter framework
- **[Weight System](weights.md)** - Weight aggregation logic
- **[Preprocessing](../preprocessing/indexer.md)** - Call graph extraction

## References

- **Implementation**: [static_reachability.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/static_reachability.py)
- **Integration**: [main.py L358-359](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L358-L359)
- **Call Graph Source**: Function Indexer preprocessing
