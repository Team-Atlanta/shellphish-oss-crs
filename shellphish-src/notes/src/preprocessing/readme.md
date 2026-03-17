# Preprocessing Phase

## Overview

The preprocessing phase transforms raw CRS tasks into structured, analyzable artifacts. While conceptually organized into three stages (**Build**, **Analysis**, **Indexing**), the actual execution model uses **parallel processing** for efficiency. Bob the Builder creates initial builds, then Analyzer components, CLANG/ANTLR extractors, and CodeQL analysis run in parallel, followed by index generation. This phase creates all foundational data structures required by downstream vulnerability analysis and patching components.

### Whitepaper Reference
> From [Section 4: Preprocessing](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/notes/src/whitepaper/Artiphishell-3.md#4-preprocessing)

### Three-Stage Pipeline

1. **[Bob the Builder](bob-the-builder.md)** - Creates multiple instrumented builds
2. **[Analyzer](analyzer.md)** - Extracts metadata and identifies harnesses
3. **[Indexer](indexer.md)** - Generates function indices for efficient lookup

## Architecture

### Orchestration
The preprocessing pipeline is defined in [pipelines/preprocessing.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml), which declares all repository classes, data dependencies, and task execution order.

### Repository Types
Three main repository classes store different data types:

- **MetadataRepository** - Parseable YAML/JSON metadata (e.g., project configurations, harness info)
- **FilesystemRepository** - Directory structures as tar archives (e.g., build artifacts)
- **BlobRepository** - Single binary files (e.g., CodeQL reports, function indices)

### Key Repositories Created

**Metadata Repositories:**
- `augmented_project_metadatas` - Project metadata with harness locations
- `project_build_configurations` - Build config matrix (arch × sanitizer)
- `project_harness_infos` - Harness metadata per configuration
- `codeql_db_ready` / `codeql_analysis_ready` - Analysis completion markers

**Filesystem Repositories:**
- `canonical_build_artifacts` - Standard libFuzzer builds
- `debug_build_artifacts` - Builds with debug symbols
- `coverage_build_artifacts` - Coverage-instrumented builds
- `full_functions_jsons_dirs` - Per-function metadata JSONs

**Blob Repositories:**
- `full_functions_indices` - Function signature → file path mapping
- `codeql_reports` - CodeQL analysis results (CFG/DFG/CPG)
- `libfuzzer_reaching_functions_dicts` - Reachability analysis results

## Data Flow

### Sequential View (Conceptual)

```
CRS Task Input → OSS-Fuzz Setup → Bob the Builder → Analyzer → Indexer → Downstream
```

### Parallel Execution View (Actual Implementation)

```
CRS Task Input
    ↓
OSS-Fuzz Repository Setup
    ↓
Bob the Builder (Multiple Builds)
    ├─ Canonical Build (libFuzzer, priority: 20B) ────┐
    ├─ Debug Build (with symbols)                      ├─→ Build Artifacts
    ├─ Coverage Build (C/Java)                         │
    └─ Delta Build (HEAD~1, Java only)                ┘
    ↓
┌────────────────── Parallel Phase ──────────────────────┐
│                                                         │
│  Analyzer Components         Function Extractors       │
│  ├─ Target Identifier       ├─ CLANG Indexer (C/C++)  │
│  ├─ Config Splitter         └─ ANTLR4-guy (Java)      │
│  ├─ CodeQL Build                     ↓                 │
│  │   └─ CodeQL Analysis     full_functions_jsons_dirs │
│  └─ SARIF Processing                                   │
│           ↓                           ↓                 │
│  augmented_project_metadatas   function JSONs          │
│                                                         │
└─────────────────────────────────────────────────────────┘
    ↓
Function Index Generator (indexer.py)
    ├─ Multiprocessing (signature-to-file mapping)
    ├─ File-to-functions mapping
    └─ RemoteFunctionResolver API (with caching)
    ↓
Output Repositories
    ├─ full_functions_indices
    ├─ augmented_project_metadatas
    ├─ project_harness_infos
    ├─ codeql_reports
    └─ quickseed_codeql_reports
    ↓
Downstream Components
    ├─ QuickSeed (seed generation)
    ├─ Grammar-Guy (grammar synthesis)
    ├─ Discovery-Guy (vulnerability discovery)
    └─ Patch Generation
```

**Key Insight:** The Analyzer and Function Extraction phases run in parallel after Bob the Builder completes. This maximizes throughput by leveraging independent processing of build artifacts, metadata extraction, and function indexing.

## Implementation Details

### Task Service Architecture
All builds execute in containerized environments using the task service:

- **Priority Scheduling** - Early-phase tasks get higher priority (e.g., canonical_build: 20B)
- **Resource Quotas** - CPU/memory limits per task (default: 6 CPU, 26Gi RAM for builds)
- **Timeout Management** - 180-minute timeout for long-running builds
- **Auto-scaling** - Dynamic resource allocation based on workload

### Build Configuration Matrix
The [Configuration Splitter](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/configuration-splitter/split_configurations.py#L16-L17) creates M × N combinations:

**Supported Architectures:** x86_64
**Supported Sanitizers:** address, undefined, memory, thread

Each combination produces a `BuildConfiguration` object stored in `project_build_configurations` repository.

### Delta Mode Support
For patch analysis (delta mode), the system builds both:
- **Current version** (HEAD) - Standard builds
- **Base version** (HEAD~1) - Separate delta builds for comparison

This enables differential analysis to identify vulnerabilities introduced by code changes.

### CodeQL Integration
CodeQL analysis ([components/codeql/pipeline.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/pipeline.yaml)) produces:

1. **Database Creation** - `codeql_build` task creates CodeQL database from build
2. **Query Execution** - Extracts CFG, DFG, CPG via analysis queries
3. **Vulnerability Detection** - Runs CWE-specific queries for security analysis
4. **Quickseed Analysis** - Identifies sinks and reachability information

Results stored in `codeql_reports` and `quickseed_codeql_reports` repositories.

## Performance Optimizations

### Parallel Processing
The indexer uses multiprocessing for efficient index generation:
- CPU count detection for optimal parallelism
- Chunk-based processing (512 items or files/CPUs)
- Progress tracking via tqdm

Reference: [indexer.py:79-94](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L79-L94)

### Caching Strategy
The RemoteFunctionResolver API provides cached function lookups:
- Reduces redundant index queries
- Improves downstream component performance
- Initialized by [functionresolver-server-init.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/functionresolver-server-init.py)

### Compressed Storage
Large repositories use compression to reduce storage:
- `compress_backend: true` - Compressed backend storage
- `compress_backup: true` - Compressed backups
- Applied to source repositories and analysis results

## Language Support

### C/C++ Projects
- **Harness Detection** - Uses llvm-symbolizer to locate `LLVMFuzzerTestOneInput`
- **Symbol Extraction** - Parses `.shellphish_harness_symbols.json` files
- **Build System** - OSS-Fuzz infrastructure with sanitizer support

Reference: [analyze_target.py:158-182](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/target-identifier/analyze_target.py#L158-L182)

### Java Projects
- **Harness Detection** - Regex extraction of `--target_class` parameter
- **Fuzzer Integration** - Jazzer-based fuzzing support
- **Edit Distance Matching** - Levenshtein distance for fuzzy harness location

Reference: [analyze_target.py:183-296](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/target-identifier/analyze_target.py#L183-L296)

## Error Handling

### Build Failures
- Canonical builds require success (`require_success: true`)
- Exit code 33 triggers retry logic
- Failure metadata stored in `canonical_build_delta_failures`

### Harness Resolution
- Falls back to edit-distance matching when exact match fails
- Searches for `fuzzerTestOneInput` across all Java files
- Returns partial SourceLocation if resolution incomplete

### Telemetry
All components use OpenTelemetry for observability:
- Span tracking for task execution
- Event logging for debugging
- Status reporting (success/failure)

## Downstream Dependencies

The preprocessing outputs are consumed by:

- **QuickSeed** - Uses CodeQL reachability for seed generation
- **Grammar-Guy** - Uses function indices for targeted grammar synthesis
- **AFLuzzer/Jazzmine** - Uses instrumented builds for fuzzing
- **LLuMinar** - Uses function metadata for vulnerability analysis
- **Patch Generation** - Uses debug symbols and source locations

## Configuration

### Environment Variables
- `LOG_LEVEL` - Logging verbosity (default: INFO)
- `IN_K8S` - Kubernetes deployment flag (adds --push to builds)
- `INITIAL_BUILD_CPU/MEM` - Build resource limits
- `CRS_TASK_NUM` - Concurrent task identifier

### Repository Paths
All repositories defined in [preprocessing.yaml:1-100](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L1-L100).
