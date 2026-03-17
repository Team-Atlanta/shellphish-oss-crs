# Points of Interest (POI)

## Overview

The **Points of Interest (POI) subsystem** identifies and prioritizes functions most likely to contain vulnerabilities, enabling the CRS to efficiently allocate expensive analysis resources (fuzzing, PoC generation) to high-value targets.

**Core Goal**: Reduce thousands of functions to a ranked list of ~100 high-priority candidates.

**Key Insight**: The POI system doesn't eliminate functions entirely—it ranks them by vulnerability likelihood, allowing downstream components to process top candidates first until budgets are exhausted.

## Architecture

The POI subsystem has **two independent pipelines** for identifying vulnerable code locations:

### 1. CodeSwipe - Static Analysis POI (Proactive)

```
┌──────────────────────────────────────────────────────────────┐
│               CodeSwipe - Static Analysis POI                 │
│                    (Proactive Analysis)                       │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  Input: Source Code + Function Indices + Analysis Results    │
│         (Semgrep/CodeQL/ScanGuy/DiffGuy reports)              │
│                                                               │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Filter Pipeline (8 filters organized by type):        │ │
│  │                                                         │ │
│  │  Static Analysis Filters:                              │ │
│  │    • Semgrep (pattern-based rules)       2.0-23.0      │ │
│  │    • CodeQL (dataflow queries)           1.0-8.0+      │ │
│  │                                                         │ │
│  │  LLM-Based Filter:                                      │ │
│  │    • LLuMinar/ScanGuy (semantic)         0/10.0        │ │
│  │                                                         │ │
│  │  Delta Mode Filter:                                     │ │
│  │    • DiffGuy (diff analysis)             2.0-12.0      │ │
│  │                                                         │ │
│  │  Heuristic Filter:                                      │ │
│  │    • Dangerous Functions (unsafe APIs)   0.1-8.0       │ │
│  │                                                         │ │
│  │  Reachability Filters:                                  │ │
│  │    • Static Reachability (call graph)    0/1.0         │ │
│  │    • Dynamic Reachability (coverage)     0/1.0         │ │
│  │                                                         │ │
│  │  Utility Filter:                                        │ │
│  │    • Skip Tests (test file exclusion)    0.0           │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                               │
│  Weight Aggregation: priority_score = Σ(filter.weight)       │
│                                                               │
│  Output: Top 100 Functions (CodeSwipeRanking YAML)           │
│          Sorted by priority_score (descending)                │
│                                                               │
└───────────────────────────┬───────────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────────┐
              │  Downstream Components:     │
              ├─────────────────────────────┤
              │  • AIJON                    │
              │    (fuzzing instrumentation)│
              │  • Discovery Guy            │
              │    (PoC generation)         │
              │  • Fuzzing Agents           │
              │    (AFL, Jazzmine)          │
              │  • QuickSeed                │
              │    (seed generation)        │
              └─────────────────────────────┘
```

### 2. POI Guy - Fuzzing Crash POI (Reactive)

```
┌──────────────────────────────────────────────────────────────┐
│                POI Guy - Fuzzing Crash POI                    │
│                    (Reactive Analysis)                        │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  Input: PoVReport (fuzzing crash reports)                    │
│                                                               │
│  Processing:                                                  │
│  • Parse stack traces from crash reports                     │
│  • Resolve function symbols via FunctionResolver             │
│  • Filter out harness/test code                              │
│  • Enrich with source location metadata                      │
│                                                               │
│  Output: POIReport JSON (crash locations + metadata)         │
│                                                               │
└───────────────────────────┬───────────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────────┐
              │  Downstream Components:     │
              ├─────────────────────────────┤
              │  • Invariant Guy            │
              │    (root cause analysis)    │
              └─────────────────────────────┘
```

## Documentation Structure

### Core Documentation

📖 **[CodeSwipe Overview](codeswipe-overview.md)** - **START HERE**
- Complete system design and workflow
- Filter framework architecture
- Input/output formats
- Downstream integration
- Performance considerations

📊 **[Weight System](weights.md)**
- Detailed weight values for all filters
- Weight calculation examples
- Tuning guidelines
- Design rationale

### Filter Documentation

#### Static Analysis Filters

🔍 **[Semgrep Rules](semgrep-rules.md)**
- 21 custom rules for Java/C/C++
- Pattern-based vulnerability detection
- Weight: 2.0-23.0 based on severity

🔍 **[CodeQL Queries](codeql-queries.md)**
- 11 C/C++ queries, 15 Java queries
- Dataflow-based semantic analysis
- Weight: 1.0-8.0+ based on query type

#### LLM-Based Filters

🤖 **[LLuMinar (ScanGuy)](lluminar.md)**
- Fine-tuned LLM vulnerability detection
- Agent scaffold with context retrieval
- Weight: 0 or 10.0 (binary prediction)

#### Delta Mode Filters

🔄 **[DiffGuy](diffguy.md)**
- Delta mode differential analysis
- Three analyzers: function/boundary/file diff
- Weight: 2.0-12.0 based on diff category
- Only active in delta mode

#### Heuristic Filters

📈 **[Dangerous Functions](dangerous-functions.md)**
- Unsafe C/C++ API detection (strcpy, gets, system, etc.)
- Code structure patterns (loops)
- Weight: 0.1-8.0 based on API risk

#### Reachability Filters

🔗 **[Static Reachability](static-reachability.md)**
- Call graph-based reachability from entry points
- Weight: 0 or 1.0 (binary)

🔗 **[Dynamic Reachability](dynamic-reachability.md)**
- Runtime coverage from fuzzing campaigns
- Harness/grammar metadata enrichment
- Weight: 0 or 1.0 (binary)

#### Utility Filters

🚫 **[Skip Tests](skip-tests.md)**
- Test file identification and exclusion
- Weight: 0.0 (zeroes priority_score via metadata)

## Quick Start

### Understanding POI Flow

1. **Read**: [CodeSwipe Overview](codeswipe-overview.md) to understand the core framework
2. **Deep Dive**: Check individual filter documentation for specific heuristics
3. **Weight Tuning**: See [weights.md](weights.md) to understand and adjust scoring
4. **Integration**: Learn how downstream components consume rankings

### Key Concepts

**CodeBlock**: The fundamental unit - a function with metadata and filter results

**Filter**: Independent analysis module that assigns weights to code blocks

**priority_score**: Aggregated weight from all filters (sum of individual weights)

**Ranking**: Sorted list of functions by priority_score (top ~100 output)

## Data Flow Summary

```
Source Code + Function Indices
         │
         ▼
   CodeSwipe Filter Framework
         │
         ├─→ Semgrep Filter ──────→ weight
         ├─→ CodeQL Filter ──────→ weight
         ├─→ LLuMinar Filter ────→ weight
         ├─→ DiffGuy Filter ─────→ weight (delta mode)
         ├─→ Dangerous Functions ─→ weight
         └─→ Reachability ───────→ weight
         │
         ▼
   Weight Aggregation
   priority_score = Σ weights
         │
         ▼
   Sort & Rank Functions
         │
         ▼
   CodeSwipeRanking YAML
   (Top 100 Functions)
         │
         ├─→ AIJON (fuzzing)
         ├─→ Discovery Guy (PoC)
         ├─→ Fuzzing Agents
         └─→ QuickSeed
```

## Operating Modes

### Delta Mode (Patch Analysis)

**When**: Git diff is provided

**Focus**: Changed and newly-reachable functions

**Key Filter**: DiffGuy assigns high weights (up to 12.0) to:
- Functions in overlap (changed + reachable + in modified file)
- Newly exposed API surface
- Functions with new vulnerability patterns

**Use Case**: Fast patch review, CI/CD integration

### Full Mode (Complete Audit)

**When**: No diff provided

**Focus**: Entire codebase

**Filters**: All except DiffGuy

**Use Case**: Initial assessment, comprehensive security audit

## Performance Characteristics

**Speed**: Optimized for large codebases (thousands of functions)

**Parallelization**: Filters run independently (can be parallelized)

**Cost Management**: Expensive filters (LLM) run last on pre-filtered sets

**Output Limit**: Default 100 functions (configurable)

## Integration Points

### Inputs from Preprocessing

- **Function Indices**: [Clang Indexer](../preprocessing/indexer.md) or Java equivalent
- **Call Graphs**: For reachability analysis

### Inputs from Static Analysis

- **Semgrep Reports**: JSON format with findings
- **CodeQL Reports**: YAML format with query results
- **DiffGuy Reports**: `diffguy_report.json` (delta mode)

### Inputs from LLM Analysis

- **ScanGuy Results**: `scan_results.json` with vulnerability predictions

### Outputs to Downstream

- **CodeSwipeRanking YAML**: Ranked function list with weights and metadata
- Consumed by: AIJON, Discovery Guy, fuzzing agents, QuickSeed

## Component Locations

### CodeSwipe (Static Analysis POI)

- **CodeSwipe**: [components/code-swipe/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/code-swipe)
- **ScanGuy (LLuMinar)**: [components/scanguy/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/scanguy)
- **DiffGuy**: [components/diffguy/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/diffguy)
- **Semgrep Rules**: [components/semgrep/rules/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/semgrep/rules)
- **CodeQL Queries**: [components/codeql/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/codeql)

### POI Guy (Fuzzing Crash POI)

- **POI Guy**: [components/poiguy/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/poiguy) - Parses fuzzing crash reports (PoVReport) and extracts POIs from stack traces. Separate pipeline from CodeSwipe.

## Related Documentation

- **[Preprocessing](../preprocessing/readme.md)** - Function index generation
- **[Vulnerability Identification](../vulnerability-identification/readme.md)** - POI consumers
- **[Whitepaper Section 5](../whitepaper/Artiphishell-3.md#5-points-of-interests)** - POI design overview

## Design Philosophy

From the original design document:

> "The goal is to take a large code base with potentially thousands of functions and reduce it down into a prioritized list of maybe 100 functions... by prioritizing, our systems are going to be looking at those ones first until each component runs out of its individual budget."

**Key Principles**:
1. **Ranking over filtering**: Don't eliminate, prioritize
2. **Modular design**: Easy to add new heuristics
3. **Transparent scoring**: Weights are visible and debuggable
4. **Cost-aware**: Expensive analysis only on promising candidates
5. **Budget-friendly**: Downstream components decide when to stop
