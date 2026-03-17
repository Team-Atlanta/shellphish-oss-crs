# Dynamic Reachability Filter

## Overview

The **Dynamic Reachability Filter** identifies functions that are **actually executed** during fuzzing runs based on runtime coverage data stored in the analysis graph (Neo4j database). Unlike [static reachability](static-reachability.md) which uses call graph analysis, this filter provides **runtime-verified reachability**.

**Purpose**: Prioritize functions with proven execution paths and provide harness/grammar metadata for targeted fuzzing.

**Location**: [dynamic_reachability.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py)

## How It Works

### 1. Analysis Graph Query

The filter queries a **Neo4j graph database** containing runtime coverage information from fuzzing campaigns.

**Query** ([lines 41-58](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L41-L58)):

```cypher
MATCH (f:CFGFunction)
WHERE EXISTS { MATCH (:HarnessInputNode)-[:COVERS]->(f) }
   OR EXISTS { MATCH (:Grammar)-[:COVERS]->(f) }
CALL {
  WITH f
  MATCH (src)-[:COVERS]->(f)
  WHERE src:HarnessInputNode OR src:Grammar
  WITH src
  ORDER BY CASE WHEN src:HarnessInputNode THEN src.first_discovered_timestamp
                ELSE datetime('1970-01-01T00:00:00Z') END
  RETURN
    CASE WHEN src:HarnessInputNode THEN src.harness_name END AS harness_name,
    CASE WHEN src:Grammar THEN src END AS grammar
  LIMIT 1
}
RETURN f, harness_name, grammar
```

**Graph Schema**:
- **Nodes**:
  - `CFGFunction`: Functions in the codebase
  - `HarnessInputNode`: Specific fuzzing inputs that triggered coverage
  - `Grammar`: Grammar definitions used for generation
- **Relationships**:
  - `[:COVERS]`: Links inputs/grammars to functions they execute

### 2. Coverage Source Classification

**Method**: `get_covered_functions()` ([lines 36-80](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L36-L80))

For each covered function, the filter determines **how** it was reached:

```python
metadata = {}
if harness_name:
    metadata["harness_name"] = harness_name  # Covered by specific harness
else:
    metadata["grammar"] = Grammar.inflate(grammar_node)  # Covered via grammar
```

**Storage** ([lines 73-78](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L73-L78)):
```python
identifier: FUNCTION_INDEX_KEY = function.identifier

if identifier not in self.matches_by_func_identifier:
    self.matches_by_func_identifier[identifier] = []

self.matches_by_func_identifier[identifier].append((function, metadata))
```

### 3. Function Resolution

**Challenge**: Coverage identifiers from the analysis graph may not exactly match function index keys in the focus repository.

**Solution** ([lines 104-122](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L104-L122)):

```python
# Step 1: Try direct matching
for ident in self.matches_by_func_identifier.keys():
    if ident in code_block_map:
        # Direct match found
        pass
    else:
        # Need resolution
        to_resolve.append(ident)

# Step 2: Use FunctionResolver for fuzzy matching
if to_resolve and resolver:
    resolved, missing = resolver.find_matching_indices(to_resolve)
```

**FunctionResolver** ([line 104](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L104)):
- Handles path differences (e.g., `/src/foo.c` vs `./foo.c`)
- Resolves symbol name variations
- Maps instrumented binary functions back to source functions

### 4. Filter Application

**Method**: `apply()` ([lines 95-169](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L95-L169))

For each code block:

```python
def apply(self, code_blocks: List[CodeBlock]) -> List[FilterResult]:
    # ... resolution logic ...

    for code_block in code_blocks:
        if code_block.function_key in found_blocks:
            metadata = {
                "reachable": True,
                "has_harness_input": True,
            }

            _, hit_metadata = found_blocks[code_block.function_key]
            if hit_metadata.get("harness_name"):
                metadata["harness_name"] = hit_metadata["harness_name"]

            res = FilterResult(weight=1.0, metadata=metadata)
        else:
            res = FilterResult(weight=0.0)

        out.append(res)
    return out
```

## Weight Assignment

| Condition | Weight | Metadata |
|-----------|--------|----------|
| Function covered by harness | **1.0** | `{"reachable": True, "has_harness_input": True, "harness_name": "..."}` |
| Function covered by grammar | **1.0** | `{"reachable": True, "has_harness_input": True, "grammar": {...}}` |
| Function NOT covered | **0.0** | `{}` |

**Rationale**: Same weight as static reachability (1.0), but with richer metadata for downstream targeting.

## Metadata Fields

### For Harness-Covered Functions

```python
{
    "reachable": True,
    "has_harness_input": True,
    "harness_name": "fuzz_parser"  # Name of the harness that reached this function
}
```

### For Grammar-Covered Functions

```python
{
    "reachable": True,
    "has_harness_input": True,
    "grammar": Grammar(...)  # Grammar object that can reach this function
}
```

**Grammar Object**: Contains grammar rules and generation patterns for creating targeted inputs.

## Analysis Graph Integration

### Data Flow

```
Fuzzing Runs
    ↓
Coverage Instrumentation
    ↓
Runtime Coverage Data
    ↓
Analysis Graph (Neo4j)
    ├─ CFGFunction nodes
    ├─ HarnessInputNode nodes
    ├─ Grammar nodes
    └─ [:COVERS] relationships
    ↓
Dynamic Reachability Filter (this component)
    ↓
POI Metadata
```

### Graph Population

The analysis graph is populated by:

1. **Fuzzing Agents**: Record which inputs cover which functions
2. **Grammar Guy**: Track grammar-generated inputs and their coverage
3. **Coverage Trackers**: Map runtime execution to source functions

**Graph Location**: Configured via Neo4j connection (typically in `analysis_graph` library)

## Example

### Scenario: Fuzzing a Parser

**Harnesses**:
- `fuzz_json_parser`: Entry point for JSON parsing
- `fuzz_xml_parser`: Entry point for XML parsing

**Functions**:
- `parse_json()`: Only reached by `fuzz_json_parser`
- `validate_utf8()`: Reached by both harnesses
- `decode_base64()`: Not covered yet

### Filter Results

| Function | Covered? | Weight | Metadata |
|----------|----------|--------|----------|
| `parse_json` | ✓ (harness) | 1.0 | `{"reachable": True, "has_harness_input": True, "harness_name": "fuzz_json_parser"}` |
| `validate_utf8` | ✓ (harness) | 1.0 | `{"reachable": True, "has_harness_input": True, "harness_name": "fuzz_json_parser"}` ¹ |
| `decode_base64` | ✗ | 0.0 | `{}` |

¹ First harness by timestamp is selected ([line 50](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L50))

## Use Cases

### 1. Targeted Fuzzing

**Downstream Consumer**: Fuzzing agents (AFLuzzer, Jazzmine)

**Usage**: Use `harness_name` to direct fuzzing efforts

```python
# In fuzzing coordinator
for poi in top_pois:
    harness = poi["metadata"].get("harness_name")
    if harness:
        # Allocate more fuzzing budget to this harness
        allocate_budget(harness, budget=HIGH_PRIORITY)
```

### 2. Grammar-Based Seed Generation

**Downstream Consumer**: Grammar Guy, QuickSeed

**Usage**: Use grammar metadata to generate targeted seeds

```python
# In seed generator
for poi in pois:
    grammar = poi["metadata"].get("grammar")
    if grammar:
        # Generate seeds using the grammar that reaches this POI
        seeds = generate_from_grammar(grammar, target_function=poi["function_index_key"])
```

### 3. Coverage Gaps Identification

**Pattern**: Functions with high static analysis scores but `weight=0.0` from dynamic reachability are **uncovered but potentially vulnerable**.

**Use Case**: Prioritize creating new harnesses or grammars to reach these functions.

```python
# Find high-priority uncovered functions
for block in code_blocks:
    static_score = sum(block.weights.values()) - block.weights.get("dynamic_reachability", 0)
    is_covered = block.filter_results["dynamic_reachability"].weight > 0

    if static_score > THRESHOLD and not is_covered:
        # High-priority but uncovered - create new harness
        recommend_harness_for(block)
```

## Comparison: Static vs Dynamic Reachability

| Aspect | [Static Reachability](static-reachability.md) | Dynamic Reachability |
|--------|----------------------------------------------|---------------------|
| **Basis** | Call graph analysis | Runtime coverage data |
| **Coverage** | Over-approximation (all possible paths) | Under-approximation (only executed paths) |
| **Accuracy** | May include unreachable paths (virtual calls, dead code) | High precision (proven executable) |
| **Speed** | Fast (one-time graph traversal) | Requires prior fuzzing campaign |
| **Metadata** | Simple boolean | Harness name OR grammar object |
| **Use Case** | Pre-filtering, dead code detection | Targeted fuzzing, harness selection |
| **Dependency** | Function indices + call graph | Analysis graph + fuzzing runs |

### Complementary Roles

**Both filters can assign `weight=1.0` to the same function**, resulting in `weight=2.0` total from reachability alone:

```python
# Example: Statically reachable AND dynamically covered
{
    "priority_score": 26.0,
    "weights": {
        "semgrep": 10.0,
        "codeql": 8.0,
        "simple_reachability": 1.0,     # ← Static
        "dynamic_reachability": 1.0,    # ← Dynamic
        "dangerous_functions": 6.0
    }
}
```

## Performance Considerations

### Neo4j Query Optimization

**Query Complexity**: Depends on:
- Number of functions in codebase (V)
- Number of coverage records (E)
- Neo4j index configuration

**Optimization** ([line 50](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L50)):
- `ORDER BY first_discovered_timestamp` + `LIMIT 1`: Efficiently selects earliest coverage
- Indexes on `CFGFunction.identifier` recommended

### Function Resolution Cost

**Comment** ([lines 98-100](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L98-L100)):
> "We have to do this in reverse because the coverage identifiers may be in the wrong location... but its too expensive to run on every coverage identifier"

**Strategy**:
1. Try direct matching first (fast)
2. Batch resolution for mismatches (slower but only for subset)

## Limitations

### 1. Requires Prior Fuzzing

**Problem**: Dynamic reachability depends on existing fuzzing coverage.

**Impact**: For new codebases or new code, this filter will return mostly `weight=0.0` until sufficient fuzzing has occurred.

**Mitigation**: Use [static reachability](static-reachability.md) as a fallback.

### 2. Timestamp Tiebreaking

**Issue** ([line 50](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L50)): When a function is covered by multiple harnesses, only the **first one** (by timestamp) is recorded.

**TODO** ([lines 132-134](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L132-L134)):
```python
# TODO better handle multiple harnesses reachable to the same function?
for hit, hit_metadata in hits:
    metadata.update(hit_metadata)
```

**Impact**: Metadata may only reflect one harness, even if multiple harnesses reach the function.

### 3. Analysis Graph Availability

**Requirement**: The filter requires `analysis_graph` library and Neo4j connection.

**Fallback** ([lines 85-87](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L85-L87)):
```python
if analysis_graph is None:
    self.warn("analysis_graph not found, dynamic reachability disabled")
    return
```

**Impact**: If the analysis graph is unavailable, all functions get `weight=0.0`.

## Configuration

**Filter Name**: `dynamic_reachability` ([line 30](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L30))

**Enabled by Default**: Yes ([line 31](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py#L31))

**Configuration Options**: None (uses global Neo4j connection)

**Neo4j Configuration**: Configured via `analysis_graph` library (external to this filter)

## Integration in CodeSwipe Pipeline

**Position**: After static reachability, before test filtering

**Filter Order** ([main.py L374-375](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L374-L375)):
```python
filters = [
    DiffguyFilter,
    SemgrepFilter,
    CodeQLFilter,
    ScanGuyFilter,
    SimpleReachabilityFilter,    # Static reachability first
    DangerousFunctionsFilter,
    DynamicReachabilityFilter,   # ← Dynamic reachability
    SkipTestsFilter
]
```

**Rationale for Position**:
- After static reachability (complementary signal)
- Provides rich metadata for downstream consumers
- Low overhead (just graph query)

## Output Format

**In CodeSwipeRanking YAML**:

```yaml
ranking:
  - function_index_key: "parser.c:parse_json:123"
    priority_score: 26.0
    weights:
      semgrep: 10.0
      codeql: 8.0
      simple_reachability: 1.0      # Static
      dynamic_reachability: 1.0     # ← Dynamic
      dangerous_functions: 6.0
    metadata:
      reachable: true
      has_harness_input: true
      harness_name: "fuzz_json_parser"  # ← Rich metadata
      semgrep: ["buffer-overflow"]
      codeql: ["uaf"]
```

## Related Documentation

- **[Static Reachability Filter](static-reachability.md)** - Call graph-based reachability
- **[CodeSwipe Overview](codeswipe-overview.md)** - Complete filter framework
- **[Weight System](weights.md)** - Weight aggregation logic
- **[Analysis Graph]** - Neo4j schema and population (external documentation)

## References

- **Implementation**: [dynamic_reachability.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/dynamic_reachability.py)
- **Integration**: [main.py L374-375](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/main.py#L374-L375)
- **Function Resolver**: [function_resolver.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py)
