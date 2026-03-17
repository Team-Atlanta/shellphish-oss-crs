# Indexer

## Summary

The Indexer phase extracts function-level metadata from source code and creates efficient lookup indices. It consists of two stages: **Function Extraction** (via CLANG for C/C++ or ANTLR4 for Java) generates raw function JSONs, then **Index Generation** (indexer.py) processes these into two key data structures: **signature-to-file mapping** (for fast lookups) and **file-to-functions mapping** (for context retrieval). The indexing process uses multiprocessing for parallel processing and exposes results via the RemoteFunctionResolver API with caching.

> From whitepaper [Section 4.3](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/notes/src/whitepaper/Artiphishell-3.md#43-indexer):
>
> After the Analyzer has completed its tasks, the Indexer agent creates a separate repository of function-related metadata. This repository is critical for the efficient and consistent access to function-related information across all agents. This is achieved using CLANG's and ANTLR's indexing capabilities to produce a list of functions with a unique identifier and a clear association between functions and their locations in the code base. This information is exposed using a dedicated API with caching to improve the speed and scalability of access.

## Components

### Stage 1: Function Extraction

**For C/C++ Projects:**

**Implementation:** [components/clang-indexer/pipeline.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clang-indexer/pipeline.yaml)

- Uses CLANG's AST traversal to extract function definitions
- Generates one JSON file per function in `full_functions_jsons_dirs`
- Contains complete function metadata (signature, source code, location)

**For Java Projects:**

**Implementation:** [components/antlr4-guy/pipeline.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/antlr4-guy/pipeline.yaml)

- Uses ANTLR4 parser to extract method definitions
- Processes Java source files via bottom-up parsing
- Generates JSON files with method metadata

### Stage 2: Index Generation

**Main Script:** [components/function-index-generator/indexer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py)

**API Server:** [components/function-index-generator/functionresolver-server-init.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/functionresolver-server-init.py)

## Index Generation Process

### 1. Function Index Processing

The [`process_file_for_meta_index`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L40-L76) function converts full function metadata into reduced indices:

**Input:** Raw `FunctionIndex` JSON files containing:

- Full function signature
- Complete source code
- Start/end line and column numbers
- File path and container information
- Byte offsets

**Output:** `ReducedFunctionIndex` containing:

- Function name and signature
- Source location (file, line, column)
- Line map (optional, for detailed context)
- Relative path to JSON file
- Target container path

**Function Signature Format** ([Line 51](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L51)):

```text
<target_container_path>:<start_line>:<start_column>::<signature>
```

Example: `/src/lib/parser.c:42:5::int parse_input(char* buf, size_t len)`

### 2. Parallel Processing

The indexer uses multiprocessing for efficiency ([Lines 79-94](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L79-L94)):

**Chunking Strategy:**

- Chunk size: min(512, files/num_cpus + 1)
- Distributes work evenly across available CPUs
- Progress tracking via tqdm

**Merging:**

- Parallel chunks merged into final dictionary
- Maps function signature → relative JSON file path
- Validated via pydantic models before output

### 3. Two Operating Modes

**Full Index Mode** ([Lines 133-175](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L133-L175)):

Creates two indices:

1. **SignatureToFile** (`full_functions_indices`):
   - Maps function signature → JSON file path
   - Enables fast lookup by signature
   - Used for targeted function queries

2. **FunctionsByFile** (`full_functions_by_file_index_jsons`):
   - Maps source file → list of functions
   - Organized by `target_container_path`
   - Used for file-level context retrieval

**Commit Index Mode** ([Lines 97-130](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L97-L130)):

- Processes multiple commits separately
- Creates `CommitToFunctionIndex` mapping
- Used for delta mode analysis (tracking function changes across commits)
- No line maps generated (optimization for delta analysis)

## Data Structures

### FunctionIndex (Input)

```python
{
  "funcname": "parse_input",
  "signature": "int parse_input(char* buf, size_t len)",
  "filename": "parser.c",
  "target_container_path": "/src/lib/parser.c",
  "focus_repo_relative_path": "lib/parser.c",
  "start_line": 42,
  "end_line": 58,
  "start_column": 5,
  "end_column": 1,
  "start_offset": 1024,
  "end_offset": 1456,
  "code": "int parse_input(char* buf, size_t len) { ... }"
}
```

### ReducedFunctionIndex (Intermediate)

```python
{
  "func_name": "parse_input",
  "function_signature": "/src/lib/parser.c:42:5::int parse_input(char* buf, size_t len)",
  "filename": "parser.c",
  "start_line": 42,
  "end_line": 58,
  "start_column": 5,
  "end_column": 1,
  "start_offset": 1024,
  "end_offset": 1456,
  "line_map": {42: "int parse_input(char* buf, size_t len) {", ...},
  "indexed_jsons_relative_filepath": "lib/parser.c/parse_input.json",
  "target_container_path": "/src/lib/parser.c",
  "focus_repo_relative_path": "lib/parser.c"
}
```

### SignatureToFile (Output)

```json
{
  "/src/lib/parser.c:42:5::int parse_input(char* buf, size_t len)": "lib/parser.c/parse_input.json",
  "/src/lib/utils.c:10:1::void* safe_malloc(size_t size)": "lib/utils.c/safe_malloc.json"
}
```

### FunctionsByFile (Output)

```json
{
  "/src/lib/parser.c": [
    {"func_name": "parse_input", "function_signature": "...", ...},
    {"func_name": "validate_syntax", "function_signature": "...", ...}
  ],
  "/src/lib/utils.c": [
    {"func_name": "safe_malloc", "function_signature": "...", ...}
  ]
}
```

## RemoteFunctionResolver API

### Purpose

Provides centralized, cached access to function metadata for all downstream components.

### Features

**Caching:** In-memory cache for frequently accessed functions

**API Endpoints:**

- Lookup by function signature
- Retrieve all functions in a file
- Search functions by name pattern
- Get function source code

**Performance:**

- Reduces redundant file I/O
- Improves query response time
- Scales across distributed components

### Initialization

The [functionresolver-server-init.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/functionresolver-server-init.py) script:

- Loads function indices into memory
- Starts HTTP API server
- Configures cache parameters
- Handles concurrent requests

## Integration with Pipeline

### Inputs

**From Bob the Builder:**

- `canonical_build_artifacts` - Build artifacts with source tree

**From Analyzer:**

- `augmented_project_metadatas` - Project context and harness locations

**From CLANG/ANTLR Extractors (parallel with Analyzer):**

- `full_functions_jsons_dirs` - Raw function JSONs from clang-indexer (C/C++) or antlr4-guy (Java)
- `commit_functions_jsons_dirs` - Commit-specific JSONs (delta mode)

### Outputs

**To All Downstream Components:**

- `full_functions_indices` - Signature lookup index
- `full_functions_by_file_index_jsons` - File-based index
- `commit_functions_indices` - Delta mode indices

**Used by:**

- **QuickSeed:** Locates target functions for seed generation
- **Grammar-Guy:** Identifies input parsing functions
- **LLuMinar:** Retrieves function source for vulnerability analysis
- **Patch Generation:** Resolves patch target locations
- **Root Cause Analysis:** Traces vulnerable function call chains

## Performance Optimizations

### Multiprocessing

**CPU Utilization:**

- Detects available CPU cores via `cpu_count()`
- Distributes work evenly across cores
- Typical speedup: 6-8x on 8-core systems

**Chunk Management:**

- Adaptive chunk sizing based on file count
- Minimizes inter-process communication overhead
- Balances load across workers

### Memory Efficiency

**Reduced Indices:**

- Stores minimal metadata (not full source code)
- Line maps optional (only for detailed context)
- Typical reduction: 10x smaller than full function JSONs

**Streaming Processing:**

- Processes files in batches
- Avoids loading entire dataset into memory
- Suitable for large codebases (millions of functions)

### I/O Optimization

**JSON Serialization:**

- Pydantic models ensure valid structure
- Pretty-printed for debugging (indent=4)
- Compressed when stored in BlobRepository

## Error Handling

**File Processing Errors** ([Lines 44-48](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L44-L48)):

- Logs critical errors with file path and content
- Returns None for failed files (skipped in final index)
- Continues processing remaining files

**Model Validation:**

- Pydantic validates all data structures
- Ensures type safety and consistency
- Prevents downstream errors from malformed data

**Telemetry:**

- OpenTelemetry spans track indexing operations
- Attributes: mode (full/commit), file counts
- Status tracking for debugging
