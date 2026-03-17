# Function Index Generator

The Function Index Generator is an in-house component that processes function metadata from clang-indexer to create searchable indices. It enables O(1) function lookups across the entire codebase and serves indices via RemoteFunctionResolver API for distributed analysis.

## Purpose

- Create fast lookup indices from function JSON files
- Support multiple access patterns (signature→file, file→functions, commit→functions)
- Enable distributed function resolution via REST API
- Support delta/incremental analysis with commit-based indices

## Architecture

### Pipeline Tasks

**File**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/pipeline.yaml)

1. **`generate_full_function_index`** ([Lines 14-65](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/pipeline.yaml#L14-L65))
   - Creates complete function index for entire project
   - Job quota: 0.45 CPU max
   - Authors: ammonia, clasm

2. **`generate_commit_function_index`** ([Lines 66-107](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/pipeline.yaml#L66-L107))
   - Creates per-commit indices for delta analysis
   - Job quota: 0.45 CPU max
   - Author: ammonia

### Entry Points

**Full Index**: [`run-full-function-index.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/run-full-function-index.sh)
```bash
python /function-index-generator/indexer.py --mode "full"
```

**Commit Index**: [`run-commit-function-index.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/run-commit-function-index.sh)
```bash
python /function-index-generator/indexer.py --mode "commit"
```

## Implementation

### Main Indexer

**File**: [`indexer.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py)

### Core Workflows

**Commit Mode** - `commit_to_index_json()` ([Lines 97-131](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L97-L131)):

```python
def commit_to_index_json(input_dir, output_path):
    # 1. Find all commit directories (e.g., "1_abc123...")
    commit_dirs = [d for d in input_dir.iterdir() if d.is_dir()]

    for commit_dir in commit_dirs:
        # 2. Find all *.json files in commit directory
        json_files = list(commit_dir.rglob("*.json"))

        # 3. Parallel processing with multiprocessing.Pool
        num_cpus = multiprocessing.cpu_count()
        chunk_size = min(512, (len(json_files) // num_cpus) + 1)

        with Pool(processes=num_cpus) as pool:
            results = pool.imap_unordered(
                process_file_for_meta_index,
                json_files,
                chunksize=chunk_size
            )

            # 4. Build commit index: {func_signature: relative_path}
            commit_index = {}
            for result in tqdm(results, total=len(json_files)):
                if result:
                    commit_index[result.function_signature] = \
                        result.indexed_jsons_relative_filepath

        # 5. Store in output: {commit_sha: {sig: path, ...}}
        output[commit_dir.name] = commit_index

    # 6. Write CommitToFunctionIndex JSON
    output_path.write_text(
        CommitToFunctionIndex(output).model_dump_json(indent=2)
    )
```

**Full Mode** - `full_index_json()` ([Lines 133-176](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L133-L176)):

```python
def full_index_json(input_dir, sig_to_file_path, func_by_file_path):
    # 1. Find all *.json files recursively
    json_files = list(input_dir.rglob("*.json"))

    # 2. Parallel processing
    num_cpus = multiprocessing.cpu_count()
    chunk_size = min(512, (len(json_files) // num_cpus) + 1)

    with Pool(processes=num_cpus) as pool:
        results = pool.imap_unordered(
            process_file_for_meta_index,
            json_files,
            chunksize=chunk_size
        )

        # 3. Build dual indices
        signature_index = {}  # sig -> file
        source_index = {}      # file -> [functions]

        for result in tqdm(results, total=len(json_files)):
            if result:
                # Add to signature index
                signature_index[result.function_signature] = \
                    result.indexed_jsons_relative_filepath

                # Add to source index
                file_path = result.target_container_path
                if file_path not in source_index:
                    source_index[file_path] = []
                source_index[file_path].append(result)

    # 4. Parallel merge for large signature indices
    signature_index = parallel_merge_dicts(
        [signature_index],
        num_processes=num_cpus
    )

    # 5. Write outputs
    sig_to_file_path.write_text(
        SignatureToFile(signature_index).model_dump_json(indent=2)
    )

    func_by_file_path.write_text(
        FunctionsByFile(source_index).model_dump_json(indent=2)
    )
```

### File Processing

**Method**: `process_file_for_meta_index()` ([Lines 39-76](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L39-L76))

```python
def process_file_for_meta_index(file_path: Path) -> ReducedFunctionIndex:
    try:
        # 1. Parse function JSON
        f_index = FunctionIndex.model_validate_json(file_path.read_text())

        # 2. Build function signature
        function_signature = (
            f"{f_index.target_container_path}:"
            f"{f_index.start_line}:"
            f"{f_index.start_column}::"
            f"{f_index.signature}"
        )

        # 3. Build line map (for full mode)
        line_map = {}
        if f_index.code:
            lines = f_index.code.split("\n")
            for i, line in enumerate(lines):
                line_number = f_index.start_line + i
                line_map[line_number] = line

        # 4. Create reduced index entry
        return ReducedFunctionIndex(
            func_name=f_index.funcname,
            function_signature=function_signature,
            start_line=f_index.start_line,
            end_line=f_index.end_line,
            line_map=line_map,
            indexed_jsons_relative_filepath=str(file_path),
            target_container_path=f_index.target_container_path
        )

    except Exception as e:
        log.critical("Error processing file: %s", file_path)
        log.critical("Error: %s", e)
        return None
```

### Function Signature Format

**Format** ([Line 51](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L51)):
```
{target_container_path}:{start_line}:{start_column}::{signature}
```

**Example**:
```
/src/hiredis/hiredis.c:142:5::int redisConnect(const char *ip, int port)
```

This enables:
- Unique identification across entire codebase
- Easy extraction of file, line, column
- Function signature matching

## Data Models

**From**: [`shellphish_crs_utils.models.indexer`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/models/indexer.py)

**FunctionIndex** ([Lines 70-83](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/models/indexer.py#L70-L83)):
- Full function metadata from clang-indexer
- Fields: `funcname`, `signature`, `code`, `hash`, `arguments`, etc.

**ReducedFunctionIndex** ([Lines 91-104](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/models/indexer.py#L91-L104)):
```python
{
    "func_name": "function_name",
    "function_signature": "path:line:col::signature",
    "start_line": 42,
    "end_line": 50,
    "line_map": {42: "code line 1", 43: "code line 2", ...},
    "indexed_jsons_relative_filepath": "relative/path/to/file.json",
    "target_container_path": "/src/project/file.c"
}
```

**CommitToFunctionIndex** ([Lines 85-86](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/models/indexer.py#L85-L86)):
```python
Dict[str, Dict[FUNCTION_INDEX_KEY, Path]]
# {commit_sha: {func_signature: json_path}}
```

**SignatureToFile** ([Lines 88-89](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/models/indexer.py#L88-L89)):
```python
Dict[FUNCTION_INDEX_KEY, Path]
# {func_signature: json_path}
```

**FunctionsByFile** ([Lines 106-107](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/models/indexer.py#L106-L107)):
```python
Dict[Path, List[ReducedFunctionIndex]]
# {file_path: [function1, function2, ...]}
```

## RemoteFunctionResolver Service

### Initialization

**Script**: [`functionresolver-server-init.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/functionresolver-server-init.py)

**Execution** ([pipeline.yaml Lines 59-64](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/pipeline.yaml#L59-L64)):
```bash
python /function-index-generator/functionresolver-server-init.py
```

**Workflow** ([Lines 36-123](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/functionresolver-server-init.py#L36-L123)):

1. **Package Indices** ([Lines 36-97](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/functionresolver-server-init.py#L36-L97)):
   ```python
   # Create tar archives
   tar -czf functions_index.tar function_index_json
   tar -czf functions_jsons.tar functions_jsons_dir/
   tar -czf data.tar functions_index.tar functions_jsons.tar
   ```

2. **Upload to Service** ([Lines 109-123](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/functionresolver-server-init.py#L109-L123)):
   ```python
   files = {"file": open("data.tar", "rb")}
   params = {
       "cp_name": project_name,
       "project_id": project_id
   }
   response = requests.post(
       f"{FUNC_RESOLVER_URL}/init_server",
       files=files,
       params=params
   )
   ```

3. **Service Integration** ([Lines 19-24](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/functionresolver-server-init.py#L19-L24)):
   - URL format supports task-based routing with `TASKNUM` placeholder
   - Environment variable: `CRS_TASK_NUM`

### Function Resolver Implementation

**File**: [`function_resolver.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py)

**LocalFunctionResolver** ([Lines 548-966](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py#L548-L966)):
- Direct filesystem access to indices
- Used for local/offline processing
- LRU cache (maxsize=2048) for performance

**RemoteFunctionResolver** ([Lines 967-1500](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py#L967-L1500)):
- REST API client for distributed access
- LRU cache (maxsize=512)
- Endpoints: `/get`, `/get_many`, `/find_by_funcname`, `/find_by_filename`

**Key Methods**:
- `get(key)`: Retrieve full FunctionIndex by signature
- `find_by_funcname(name)`: Find all functions with given name
- `find_by_filename(path)`: Find all functions in a file
- `resolve_source_location(srcloc)`: Map source locations to function indices ([Lines 460-545](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py#L460-L545))

### Source Location Resolution

**Matching Algorithm** ([Lines 460-545](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py#L460-L545)):

1. **Function Name Matching** ([Lines 46-80](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py#L46-L80)):
   - Exact match: Priority 1.0
   - Namespace/class prefix match: Priority 0.8
   - Substring match: Priority 0.6-0.1
   - Special handling for OSS-Fuzz prefixes

2. **Path Matching** ([Lines 93-135](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py#L93-L135)):
   - Focus repo relative path: Priority 1.0
   - Full path match: Priority 1.0
   - Partial path match: Scored by matching path components

3. **Line Number Matching** ([Lines 137-150](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py#L137-L150)):
   - Exact match: Priority 1.0
   - Within ±3 lines: Priority 0.8
   - Within function bounds: Priority 0.5

4. **Ranking Aggregation** ([Lines 501-545](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py#L501-L545)):
   - Sums all match scores
   - Returns top N matches sorted by score

## Performance Optimizations

### Multiprocessing

**Configuration** ([Lines 98-104](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L98-L104), [Lines 136-141](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L136-L141)):
```python
num_cpus = cpu_count()
chunk_size = min(512, (num_files // num_cpus) + 1)

with Pool(processes=num_cpus) as pool:
    results = pool.imap_unordered(
        process_file_for_meta_index,
        json_files,
        chunksize=chunk_size
    )
```

### Caching Strategy

- LocalFunctionResolver: `@lru_cache(maxsize=2048)` for function lookups ([Line 575](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py#L575))
- RemoteFunctionResolver: `@lru_cache(maxsize=512)` ([Line 997](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/function_resolver.py#L997))
- Multiple cache dictionaries for different query types

### Progress Monitoring

**tqdm Progress Bars** ([Lines 107](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L107), [Lines 146](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/indexer.py#L146)):
```python
for result in tqdm(results, total=len(json_files)):
    # Process results
```

## Data Flow

### Inputs

- **target_functions_jsons_dir**: Function JSONs from clang-indexer
  - Structure: `FUNCTION/*.json`, `METHOD/*.json`, `MACRO/*.json`
  - Or commit-based: `1_<commit_hash>/FUNCTION/*.json`

### Outputs

1. **full_functions_indices** (SignatureToFile):
   ```json
   {
     "/src/file.c:42:5::int func(int x)": "FUNCTION/func_file_hash.json"
   }
   ```

2. **full_functions_by_file_index_jsons** (FunctionsByFile):
   ```json
   {
     "/src/file.c": [
       {
         "func_name": "func",
         "function_signature": "...",
         "start_line": 42,
         "end_line": 50,
         "line_map": {...}
       }
     ]
   }
   ```

3. **commit_functions_indices** (CommitToFunctionIndex):
   ```json
   {
     "1_abc123": {
       "sig1": "path1.json",
       "sig2": "path2.json"
     }
   }
   ```

## Downstream Consumers

From [`preprocessing.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml):

1. **Diffguy** ([Lines 121-133](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L121-L133))
2. **Sarifguy** ([Lines 136-149](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L136-L149))
3. **CodeQL** ([Lines 191-218](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L191-L218))
4. **Corpus Guy** ([Lines 220-238](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L220-L238))
5. **Grammar Guy** ([Lines 240-263](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L240-L263))
6. **Grammaroomba** ([Lines 265-279](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L265-L279))
7. **Semgrep** ([Lines 281-295](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L281-L295))
8. **Code Swipe** ([Lines 310-330](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L310-L330))
9. **Quickseed** ([Lines 333-365](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L333-L365))
10. **Discovery Guy** ([Lines 367-401](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L367-L401))
11. **Scanguy** ([Lines 403-416](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L403-L416))
12. **Backdoorguy** ([Lines 418-428](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L418-L428))

## Testing

**Backup Testing**: [`run-fig-from-backup.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/run-fig-from-backup.sh) ([Lines 1-123](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/function-index-generator/run-fig-from-backup.sh#L1-L123))
- Interactive mode for selecting tasks and backup sources
- Supports both full and commit index generation
- Uses archived backups from `/aixcc-backups/`

## Related Components

- **[Clang Indexer](./clang-indexer.md)**: Produces function JSONs
- **[CodeQL](./codeql.md)**: Uses indices for function resolution
- **[Scanguy](./scanguy.md)**: Uses function resolver for code retrieval
