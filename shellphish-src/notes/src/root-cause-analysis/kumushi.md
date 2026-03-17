# Kumushi

## Overview

Kumushi is the root cause analysis (RCA) component in Artiphishell that identifies which functions to patch when a vulnerability is discovered. Given a crash report from fuzzing, Kumushi outputs a ranked list of 10-20 function clusters representing the most likely patch locations.

**Core Strategy**: Ensemble scoring - multiple independent analysis techniques each "vote" for suspicious functions, then Kumushi ranks functions by total vote count and outputs the top candidates.

**Production Configuration**: Always runs in HYBRID mode ([`run_kumushi.sh:43`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/kumu-shi-runner/run_kumushi.sh#L43)), using all available analysis techniques in parallel for maximum accuracy.

### Key Terminology

**PoI (Point of Interest)**: A suspicious function identified by one or more analysis techniques as a potential patch location. Defined in [`poi.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/data/poi.py).

```python
class PoI:
    function: CodeFunction        # The suspicious function
    sources: list[PoISource]      # Which analyses identified it (votes)
    crash_line_num: int           # Line where crash occurred
    crash_line: str               # Code at crash line
    report: str                   # Sanitizer report
```

**PoICluster**: A group of related PoIs that should be patched together (e.g., allocation + free for use-after-free bugs).

**PoISource**: Enum representing which analysis technique identified a PoI (Stack Trace, Git Diff, Call Trace, etc.). The enum value serves as the vote weight.

## The Ensemble Scoring Process

### High-Level Flow

```
Input: Crash report + source code
  ↓
Phase 1: Run all enabled analyses in parallel (based on mode)
  ↓
Phase 2: Collect PoIs from each analysis
  ↓
Phase 3: Merge PoIs for same function (accumulate votes)
  ↓
Phase 4: Cluster PoIs (single functions + multi-function groups)
  ↓
Phase 5: Rank clusters by vote count
  ↓
Output: Top 10-20 function clusters
```

### Mode-Based Analysis Selection

Kumushi has 4 modes that control which analyses run. In production, **only HYBRID is used** (hard-coded in deployment).

| Analysis | Weight Class | Vote Score | WEIGHTLESS | LIGHT | HEAVY | HYBRID (production) |
|----------|--------------|------------|------------|-------|-------|---------------------|
| **Stack Trace** | WEIGHTLESS | **2** (highest authority) | ✓ | ✓ | ✓ | ✓ |
| **Aurora** | HEAVY | **3** | ✗ | ✗ | ✓ | ✓ |
| **DyVA** | (special) | **4** | ✗ | ✗ | ✓ if available | ✓ if available |
| **DiffGuy** | WEIGHTLESS | **5** | ✓ (delta) | ✓ (delta) | ✓ (delta) | ✓ (delta) |
| **Git Diff** | WEIGHTLESS | **6** | ✓ (delta) | ✓ (delta) | ✓ (delta) | ✓ (delta) |
| **Variable Deps** | LIGHT | **7** | ✗ | ✓ | ✗ | ✓ |
| **Call Trace** | LIGHT | **10** (lowest authority) | ✗ | ✓ | ✗ | ✓ |

**Vote Score Meaning**: Lower = more authoritative for tie-breaking. Stack Trace (2) is the most trusted, Call Trace (10) is the least trusted.

**Note on DyVA**: Unlike other analyses, DyVA is an optional external input (pre-computed by separate DyVA agent). It only integrates into ranking if: (1) running in HEAVY/HYBRID mode, (2) DyVA report exists, and (3) DyVA found a root cause.

**Mode Selection Logic** ([`_analysis_should_run`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/root_cause_analyzer.py#L153-L159)):

```python
def _analysis_should_run(self, analysis_cls):
    return (
        self._rca_mode == RCAMode.HYBRID or  # Run everything (production default)
        (self._rca_mode == RCAMode.LIGHT and analysis_cls.ANALYSIS_WEIGHT == AnalysisWeight.LIGHT) or
        (self._rca_mode == RCAMode.HEAVY and analysis_cls.ANALYSIS_WEIGHT == AnalysisWeight.HEAVY)
    )
```

**Time Budget**:
- WEIGHTLESS: 10 seconds (testing only)
- LIGHT: 10 minutes (testing only)
- HEAVY: 20 minutes (testing only)
- HYBRID: 30 minutes (production - all analyses in parallel)

## Analysis Techniques

Each analysis technique identifies suspicious functions from a different perspective. When multiple techniques agree on a function, confidence increases.

### WEIGHTLESS Analyses (Always Run)

These run synchronously during initialization ([`__init__`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/root_cause_analyzer.py#L69-L73)) and complete in <10 seconds.

#### Stack Trace Analysis

**Source**: [`stack_trace.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/analyses/stack_trace.py)

**What it finds**: Functions in the sanitizer's crash stack trace (both main crash stack and free stack for use-after-free).

**How it works**:
1. Extracts call stack from POI report ([line 19](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/analyses/stack_trace.py#L19))
2. Maps each stack frame to indexed functions
3. Captures crash line number and code context
4. Limited to top 4 frames by ranker (configurable)

**Vote weight**: PoISource.STACK_TRACE = **2** (highest authority - most direct evidence)

**Why it matters**: Provides the crash location (crashing_location_poi) needed by Variable Dependencies and Call Trace analyses.

**Empirical basis**: 60% of bugs are within 5 functions from crash site (qualification round data).

#### Git Diff Analysis (Delta Mode Only)

**Source**: [`git_diff_analysis.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/analyses/git_diff_analysis/git_diff_analysis.py)

**What it finds**: ALL functions modified in recent commits.

**How it works**:
1. Uses [`DiffParser`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/analyses/git_diff_analysis/diff_parser.py) to parse git diff
2. Maps changed functions using commit-specific function resolver
3. Only runs when `delta_mode=True`

**Vote weight**: PoISource.COMMIT = **6** (medium authority)

**Why it matters**: In delta mode, bug MUST be in recently changed code - guarantees perfect recall.

#### DiffGuy Analysis (Delta Mode Only)

**Source**: [`diffguy.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/analyses/diffguy.py)

**What it finds**: Subset of Git Diff functions that DiffGuy agent flagged as bug-prone.

**How it works**:
1. Reads pre-computed DiffGuy report
2. DiffGuy uses LLM to analyze git diffs for bug patterns
3. Filters Git Diff results with semantic understanding

**Vote weight**: PoISource.DIFFGUY = **5** (higher authority than Git Diff - LLM-filtered)

**Why it matters**: Adds precision to Git Diff's high recall.

### LIGHT Analyses (LIGHT/HYBRID Modes)

These run in parallel during `analyze()` with 10-minute timeout each.

#### Call Trace Analysis

**Source**: [`call_trace.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/analyses/call_trace.py)

**What it finds**: All functions invoked during crash execution (up to 4,000).

**How it works**:
1. Uses [`FlexibleTracer`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/tracing/flexible_tracer.py) to instrument program
2. Runs crashing input and collects full execution trace
3. Ranks by distance from crashing function + invocation frequency ([lines 36-62](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/analyses/call_trace.py#L36-L62))
4. Stores function indices (memory optimization)

**Vote weight**: PoISource.CALL_TRACE = **10** (lowest authority - very noisy, finds 4000 functions)

**Why it matters**: Finds state-corruption bugs not visible in stack trace.

**Sets REQUIRES_NEW_PROGRAM = True**: Avoids interference with other analyses.

#### Variable Dependencies Analysis

**Source**: [`variable_dependencies.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/analyses/variable_dependencies.py)

**What it finds**: Functions that could have affected variables at crash site.

**How it works**:
1. Initialized with crashing_location_poi from Stack Trace
2. Uses CodeQL taint analysis via [`StaticAnalyzer`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/static_tools/static_analysis.py)
3. Queries for functions affecting crash-site variables
4. Language-aware (C/C++: [`variable_accesses.ql.j2`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/static_tools/codeql_query_templates/variable_accesses.ql.j2), Java: [`variable_accesses_java.ql.j2`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/static_tools/codeql_query_templates/variable_accesses_java.ql.j2))

**Vote weight**: PoISource.VAR_DEP = **7** (medium-low authority)

**Why it matters**: Finds data-flow bugs (integer overflow, wrong size calculation) where root cause is far from crash.

### HEAVY Analyses (HEAVY/HYBRID Modes)

#### Aurora Analysis

**Source**: [`aurora.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/analyses/aurora/aurora.py)

**What it finds**: Functions that appear in crash traces but rarely in benign traces.

**How it works**:
1. Requires directory of multiple crashing inputs
2. Uses [`AuroraRanker`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/analyses/aurora/aurora_ranker.py)
3. Performs 180-second fuzzing campaign to collect benign traces
4. Compares crash vs benign stack traces (statistical anomaly detection)
5. Only includes functions with score > 0.85

**Vote weight**: PoISource.AURORA = **3** (high authority - statistical evidence, score > 0.85)

**Why it matters**: High-confidence signal based on statistical evidence.

**Timeout**: 20 minutes

**Research basis**: Based on AURORA system (USENIX Security 2020).

#### DyVA Integration (Optional)

**What it finds**: Functions identified by DyVA agent via LLM-guided debugging (GDB/JDB).

**How it works**:
1. Reads pre-computed DyVA report (separate agent)
2. If root cause found, extracts function signatures ([lines 87-98](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L87-L98))
3. Creates special cluster inserted at position 1

**Vote weight**: PoISource.DYVA = **4** (very high authority - LLM-guided debugging)

**Why it matters**: Highest authority when available - deep interactive reasoning.

**Activation conditions** ([`poi_cluster_ranker.py:85-101`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L85-L101)):
1. **Mode check**: `self._mode >= RCAMode.HEAVY` (only in HEAVY/HYBRID)
2. **Report exists**: `self._program.dyva_report is not None` (DyVA report provided as input)
3. **Root cause found**: `self._program.dyva_report.found_root_cause == True` (DyVA successfully identified root cause)

**Reality**: DyVA is **not always available**. It's an optional external input that may or may not exist for a given crash. In production (HYBRID mode), Kumushi checks for DyVA results and uses them if present, but continues without them if absent.

## The Ranking Algorithm

### Core Ranking Principle

**Objective**: Rank function clusters by **confidence that they contain the root cause**.

**Two-tier sorting strategy** ([`_order_clusters:324-325`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L324-L325)):

```python
# For each cluster:
source_count = sum(len(poi.sources) for poi in cluster.pois)  # How many analyses found it
source_strength_avg = sum(sum(list(poi.sources)) for poi in cluster.pois) / source_count  # Quality of votes

# Sort by consensus first, quality second
clusters.sort(key=lambda x: (source_count, -source_strength_avg), reverse=True)
```

**Tier 1 (Primary)**: **Consensus** - More votes = higher confidence
- Function found by 3 analyses beats function found by 1 analysis
- **Rationale**: Independent analyses agreeing = convergent evidence

**Tier 2 (Tie-breaker)**: **Quality** - Lower vote score = higher authority
- Among functions with same vote count, prefer those found by more authoritative analyses
- Stack Trace (score 2) beats Call Trace (score 10)
- **Rationale**: Not all analyses are equally reliable

**Example**:
- Function A: Stack Trace (2) + Var Deps (7) + Call Trace (10) → count=3, avg=6.33
- Function B: Stack Trace (2) + Var Deps (7) → count=2, avg=4.5
- Function C: Call Trace (10) alone → count=1, avg=10

**Ranking**: A > B > C (consensus trumps everything, quality breaks ties)

### Processing Pipeline

After all analyses complete, [`PoIClusterRanker`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py) executes a 10-step pipeline to produce the final ranked list:

**1. Collection** ([`rank_poi_clusters:29-43`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L29-L43))
```python
# Gather all PoI clusters from completed analyses
# Filter by mode: only include analyses with ANALYSIS_WEIGHT <= self._mode
all_poi_clusters = [analysis.poi_clusters for analysis in self._analyses
                    if analysis.ANALYSIS_WEIGHT <= self._mode]
```

**2. Filtering** ([`_filter_poi_clusters:172-233`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L172-L233))

Remove invalid PoIs:
- Blacklist functions: `LLVMFuzzerTestOneInput`, `fuzz_target`
- Blacklist paths: `fuzz/`, `test/`, `tests/`
- Missing function or file path
- Outside source root

**3. Stack Trace Reduction** ([`_reduce_stack_trace_pois:279-292`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L279-L292))

Limit stack trace PoIs to top 4 (configurable via `_max_stack_trace`).

**4. Merging** ([`merge_intersecting_pois:155-170`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L155-L170))

**Core Logic**: If multiple analyses identify the same function, merge into single PoI with combined sources.

```python
pois_by_function = defaultdict(list)
for poi in pois:
    pois_by_function[poi.function.name].append(poi)

for func_name, pois in pois_by_function.items():
    if len(pois) > 1:
        merged_poi = PoI.merge(pois)  # Accumulates all sources
        new_pois.append(merged_poi)
```

**Example**: If Stack Trace finds function `parse()` and Variable Deps also finds `parse()`, merge into one PoI with sources=[STACK_TRACE, VAR_DEP].

**5. Clustering Round 1** ([`_cluster_pois_round_1:241-277`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L241-L277))

**Special Delta Mode Logic**:

```python
# If function appears in COMMIT/DIFFGUY AND any other analysis:
if (PoISource.COMMIT in poi.sources or PoISource.DIFFGUY in poi.sources) and len(poi.sources) > 1:
    diff_and_more_pois.append(poi)  # Create high-priority cluster
```

**Rationale**: In delta mode, a recently changed function that ALSO appears in runtime/static analysis is extremely suspicious.

**6. Ordering** ([`_order_clusters:293-327`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L293-L327))

Apply the two-tier ranking principle described above.

**Implementation details**:
```python
# Sort by (from code comment line 324):
# "number of sources (bigger better) and source strength (smaller better)"
clusters.sort(key=lambda x: (x[1], -x[2]), reverse=True)
# x[1] = source_count (bigger = higher rank)
# -x[2] = negated source_strength_avg (smaller original value = higher rank after negation)
# reverse=True = descending order
```

**Tie-breaking example** (when source_count is the same):
- Function D: Stack Trace (2) + Call Trace (10), avg=6 → key=(2, -6)
- Function E: Var Deps (7) + Call Trace (10), avg=8.5 → key=(2, -8.5)
- After reverse=True descending sort: D ranks higher (-6 > -8.5)
- **D wins because Stack Trace (2) is more authoritative than Var Deps (7)**

**7. Limit** ([lines 64-68](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L64-L68))

Cap at 10 clusters (LIGHT) or 20 clusters (HEAVY+).

**8. Clustering Round 2 - LLM** ([`_cluster_pois_round_2:108-122`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L108-L122))

In HEAVY+ modes, pass singleton clusters to [`LLMClusterGenerator`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/clustering/llm_clustering/llm_cluster_generator.py):

```python
if self._mode >= RCAMode.HEAVY:
    singleton_clusters = [c for c in poi_clusters if len(c.pois) == 1]
    llm_generator = LLMClusterGenerator(self._program, poi_clusters=singleton_clusters)
    llm_generator.analyze()  # Groups related functions (e.g., alloc/free pairs)
```

**Rationale**: Some bugs require multi-function patches (use-after-free, resource leaks). LLM recognizes semantic relationships.

**9. DyVA Insertion** ([lines 85-101](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L85-L101))

If DyVA found a root cause, insert its cluster at position 1 (just after user-specified PoIs).

**10. Deduplication** ([`merge_duplicate_clusters:137-152`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/poi_cluster_ranker.py#L137-L152))

Merge clusters with identical function sets.

### Why This Ranking Strategy Works

**Key Insight**: When independent analysis techniques agree on a function, the probability it's the root cause increases multiplicatively, not additively.

**Mathematical intuition**:
- If Stack Trace has 60% accuracy, it identifies the correct function 60% of the time
- If Variable Deps independently has 70% accuracy
- If both agree on the same function: P(correct) ≈ 1 - (1-0.6)×(1-0.7) = 88%
- Three independent confirmations → even higher confidence

**Why consensus beats authority**: A function found by 3 medium-quality analyses (count=3, avg=7) beats a function found by 1 high-quality analysis (count=1, avg=2) because convergent evidence from independent sources is stronger than single-source evidence, even if that source is highly authoritative.

**Why quality breaks ties**: When vote counts are equal, prefer functions found by more reliable analyses. This encodes empirical knowledge about which techniques are more trustworthy.

## Deployment

### Pipeline Configuration

Defined in [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/kumu-shi-runner/pipeline.yaml):

- **Task**: `kumushi` (full mode) and `kumushi_delta` (delta mode)
- **Resources**: 4 CPU, 8Gi memory
- **Max concurrent jobs**: 16
- **Priority**: 1,000,000
- **Execution**: [`run_kumushi.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/kumu-shi-runner/run_kumushi.sh)

### Hard-Coded Mode

Line 43 of [`run_kumushi.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/kumu-shi-runner/run_kumushi.sh#L43):

```bash
RCA_MODE="--hybrid-mode"  # Always HYBRID in production
```

### Input Dependencies

- **Crash data**: POI report, crashing input, crash exploration directory
- **Source code**: Analysis source, OSS-Fuzz repo
- **Build artifacts**: Coverage build, debug build
- **Function indexing**: Function JSONs, function indices (full + commit)
- **External analyses**: DiffGuy reports (delta), DyVA reports (optional)

### Output

YAML file with top 10-20 PoI clusters saved to `kumushi_output` repository.

## Performance

**Typical Timeline** (HYBRID mode, 4 cores):
- Phase 1 (WEIGHTLESS): 10 seconds
- Phase 2 (LIGHT analyses): 10 minutes parallel
- Phase 2 (Aurora): 20 minutes parallel
- Phase 3 (Ranking): 1 minute
- **Total**: ~25-30 minutes

**Accuracy** (empirical):
- WEIGHTLESS: 60-70% (testing only)
- LIGHT: 75-85% (testing only)
- HYBRID: 85-95% (production)

## Key Design Decisions

**Why ensemble?** No single analysis is perfect. Combining diverse techniques and ranking by consensus achieves higher accuracy than any individual method.

**Why HYBRID only?** After empirical testing, team chose maximum accuracy over speed. The 30-minute budget is acceptable given the importance of finding the correct patch location.

**Why these specific techniques?** Each targets different bug manifestations:
- Stack Trace: Direct crash observation (symptoms)
- Git Diff/DiffGuy: Temporal proximity (delta mode)
- Call Trace: Execution context (state corruption)
- Variable Deps: Data flow (computation bugs)
- Aurora: Statistical anomaly (high confidence)
- DyVA: Deep reasoning (highest authority)

**Why weighted voting?** Source weights encode relative reliability based on qualification round empirical data. Stack Trace (weight 2) is more reliable than Call Trace (weight 10) for tie-breaking.

## Limitations

- **Manual weight tuning**: Source weights empirically derived, not learned
- **Single-crash analysis**: No cross-crash learning
- **Timeout brittleness**: 30-minute hard limit may truncate expensive analyses
- **Language coverage**: Full support for C/C++/Java only
