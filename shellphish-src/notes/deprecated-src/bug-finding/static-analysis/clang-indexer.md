# Clang Indexer

The Clang Indexer extracts comprehensive function metadata from C/C++ projects during compilation, creating a foundation for all downstream analysis. It intercepts the build process using Bear to capture compilation commands, then uses libclang to parse each source file and extract detailed function information.

## Purpose

- Parse C/C++ source code during build to extract function-level metadata
- Generate compile_commands.json and link_commands.json for reproducible builds
- Support delta mode to identify only changed functions between commits
- Provide structured JSON output for function indices and analysis tools

## Key Features

- **Build Interception**: Uses Bear to capture all compilation commands
- **AST Parsing**: libclang 18 for full C++20 support and deep code understanding
- **Delta Analysis**: Compares HEAD vs HEAD~1 to identify changed functions
- **Parallel Processing**: joblib multiprocessing for fast indexing
- **Global Tracking**: Identifies global variable references in functions
- **Call Graph Extraction**: Finds all function calls within each function

## Architecture

### Pipeline Tasks

The component defines three tasks in [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clang-indexer/pipeline.yaml):

1. **`clang_index`** (Lines 19-105): Full indexing at HEAD commit
2. **`clang_index_base`** (Lines 107-184): Base indexing at HEAD~1 for delta mode
3. **`clang_index_delta`** (Lines 186-238): Computes delta between HEAD and HEAD~1

### Build Instrumentation

The indexer integrates with OSS-Fuzz builds via custom instrumentation:

**Instrumentation Class**: [`__init__.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/__init__.py#L16-L37)
- Tool name: `clang_indexer`
- Internal alias: `libfuzzer` (reuses libfuzzer build infrastructure)
- Builder Dockerfile: [`Dockerfile.builder`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/Dockerfile.builder)

**Build Hook**: [`compile`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/compile) script
- Captures build environment (working directory, git commit)
- Wraps build with Bear to generate `compile_commands.json`
- Invokes `clang-indexer` CLI after build completes

## Core Implementation

### Main Indexer

**File**: [`clang_indexer.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/clang_indexer.py)

**Entry Point**: [`main.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/main.py#L9-L38)
```python
clang-indexer --compile-args /out/compile_commands.json \
              --output /out/full/ \
              --threads -1  # Auto-detect, uses 50% of CPUs
```

### Indexing Workflow

**ClangIndexer.run()** method ([Lines 718-759](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/clang_indexer.py#L718-L759)):

1. **Parse compilation database** - Load compile_commands.json
2. **Resolve arguments** - Convert relative paths to absolute, normalize include directories
3. **Discover source files** - Recursively scan `/src` for C/C++ files
4. **Parallel processing** - Use joblib to process each file independently

**File Processing**: `_process_file()` method ([Lines 540-630](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/clang_indexer.py#L540-L630))

1. Parse file with libclang using compilation arguments
2. Walk AST via `cursor.walk_preorder()`
3. Process each cursor kind:
   - `FUNCTION_DECL` → `_process_function()`
   - `CXX_METHOD` → `_process_method()`
   - `MACRO_DEFINITION` → `_process_macro()`
4. Extract code, location, calls, globals for each function

### Extracted Information

For each function ([Lines 434-482](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/clang_indexer.py#L434-L482)):

```json
{
  "funcname": "function_name",
  "full_funcname": "namespace::class::function_name",
  "signature": "return_type function_name(args)",
  "filename": "file.c",
  "target_container_path": "/src/path/file.c",
  "focus_repo_relative_path": "relative/path/file.c",
  "start_line": 42,
  "end_line": 50,
  "start_column": 5,
  "end_column": 1,
  "start_offset": 1234,
  "end_offset": 1456,
  "code": "full_function_source_code",
  "hash": "md5_hash_of_code_plus_globals_plus_filepath",
  "func_calls_in_func_with_fullname": [
    {"name": "called_func", "type": "direct"}
  ],
  "global_variables": ["global_var1", "global_var2"],
  "func_return_type": "int",
  "was_directly_compiled": true,
  "is_generated_during_build": false,
  "unique_identifier": "usr_string",
  "raw_comment": "/** documentation */",
  "target_compile_args": {...}
}
```

### Key Implementation Details

**Qualified Name Resolution**: [`get_full_qualified_name()`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/clang_indexer.py#L26-L69)
- Traverses semantic parents to build fully qualified names
- Handles namespaces, classes, templates, anonymous types

**Code Extraction**: [`get_extent()`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/clang_indexer.py#L113-L165)
- Extracts source code between start/end offsets
- Validates large functions (>200 lines) for correct extent reporting
- LRU cache (maxsize=256) for performance

**Global Variable Tracking**:
- [`return_cached_global()`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish-afc-crs/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/clang_indexer.py#L171-L194) - Caches global declarations
- [`get_referenced_globals()`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/clang_indexer.py#L343-L375) - Finds globals referenced in function

## Delta Mode

Delta mode enables efficient incremental analysis by identifying only changed functions.

### Workflow

1. **Base Build**: `clang_index_base` task builds at `HEAD~1` ([Line 152](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clang-indexer/pipeline.yaml#L152))
2. **Current Build**: `clang_index` builds at HEAD
3. **Delta Computation**: [`get_changed_functions.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clang-indexer/scripts/get_changed_functions.py) computes difference

### Delta Computation Algorithm

[`get_changed_functions.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clang-indexer/scripts/get_changed_functions.py#L24-L52):

```python
base_files = get_files(base_dir)  # Function JSONs from HEAD~1
head_files = get_files(head_dir)  # Function JSONs from HEAD

for subdir in head_files.keys():
    # Set difference: new or modified functions
    changed = head_files[subdir] - base_files[subdir]

    # Special handling for failed base builds
    if base_compile_commands.read_text() == "{}":
        # Filter out directly compiled functions
        changed = filter_was_directly_compiled_false(changed)

    # Copy changed function JSONs to output
    copy_to_output(changed, out_dir)
```

### Output Structure

Changed functions organized by commit:
```
commit_functions_jsons_dirs/
└── 1_<commit_hash>/
    ├── FUNCTION/
    │   └── changed_function_*.json
    ├── METHOD/
    │   └── changed_method_*.json
    └── MACRO/
        └── changed_macro_*.json
```

## Data Flow

### Inputs

- **crs_tasks_oss_fuzz_repos**: OSS-Fuzz project source code
- **base_project_metadatas**: Project configuration (language, sanitizers)
- **delta_mode_tasks**: Trigger for delta mode (optional)

### Outputs

- **full_functions_jsons_dirs**: Complete function metadata (FUNCTION/, METHOD/, MACRO/ subdirectories)
- **commit_functions_jsons_dirs**: Only changed functions (delta mode)
- **project_compile_commands**: `compile_commands.json` from Bear
- **project_link_commands**: `link_commands.json` from Bear

### Downstream Consumers

- **Function Index Generator**: Creates searchable indices
- **CodeQL**: Uses compile commands and function metadata
- **Kumu-Shi Runner**: Analyzes changed functions for patching
- **Scanguy**: Uses function metadata for vulnerability scanning
- **Grammar-Guy**: Extracts grammar from function code

## Configuration

### Resource Limits

From [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clang-indexer/pipeline.yaml#L89-L97):
- Initial: 6 CPU, 26Gi memory
- Maximum: 10 CPU, 40Gi memory
- Timeout: 180 minutes

### Supported File Extensions

From [`defs.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/defs.py#L6-L18):
- Source: `.c`, `.cpp`, `.cc`, `.cxx`, `.c++`
- Headers: `.h`, `.hpp`, `.hh`, `.hxx`, `.h++`
- Inline: `.inl`

### Filtered Paths

[`target_info.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/target_info.py#L19-L26) - Excludes fuzzing infrastructure:
- `/src/aflplusplus`, `/src/libfuzzer`, `/src/honggfuzz`
- `/src/libprotobuf-mutator`, `/src/fuzzer-test-suite`
- `/src/shellphish` (except focus repo)

## Performance Optimizations

1. **Parallel Processing**: joblib with `cpu_count()` workers
2. **LRU Caching**: Function extent extraction cached
3. **Atomic Writes**: [`atomic_file_write()`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer/src/clang_indexer/clang_indexer.py#L324-L340) prevents race conditions
4. **Incremental Analysis**: Delta mode avoids re-indexing unchanged code

## Integration with OSS-Fuzz

The clang-indexer integrates seamlessly with OSS-Fuzz's build system:

1. **oss-fuzz-build-image** creates Docker images with clang-indexer tools installed
2. **oss-fuzz-build** executes project build.sh with Bear interception
3. **compile** script wrapper runs before/during/after build
4. **clang-indexer** CLI processes captured compilation database

This zero-modification approach works with any OSS-Fuzz project without changing build scripts.

## Error Handling

- **Build Failures**: `ALLOW_BUILD_FAIL=1` permits partial builds ([Line 95](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clang-indexer/pipeline.yaml#L95))
- **Parse Errors**: Logged but don't stop overall indexing
- **Large Functions**: Validation for incorrect extent reporting
- **Missing Compile Args**: Files indexed with default flags if no compilation database entry

## Related Components

- **[Function Index Generator](./function-index-generator.md)**: Consumes function JSONs
- **[CodeQL](./codeql.md)**: Uses compile commands for database building
- **Patch Generation Components**: Use function metadata for targeted patching
