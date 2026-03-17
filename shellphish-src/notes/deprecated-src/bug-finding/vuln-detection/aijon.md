# AIJON

AIJON is an **LLM-based code instrumentor** that adds IJON (Input-to-State Correspondence) annotations to guide AFL++ toward vulnerability-prone code paths. It uses the Analysis Graph to identify coverage-guided targets and instruments source code with `__AFL_IJON_MAX()` calls.

## Purpose

- LLM-driven source code instrumentation
- Guide AFL++ toward vulnerabilities
- Use coverage data to find paths to uncovered sinks
- Parallel instrumentation for scalability
- Generate focused seed corpuses for harnesses

## Implementation

**Main File**: [`main.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py)

**Supporting**: [`IJONJava.java`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/IJONJava.java) - Java instrumentation

## IJON Background

**IJON**: Input-to-State Correspondence annotations that expose internal program state to the fuzzer.

**Concept**:
```c
void maze_solver(int *moves, int len) {
    int x = 0, y = 0;
    for (int i = 0; i < len; i++) {
        if (moves[i] == UP) y++;
        else if (moves[i] == DOWN) y--;
        else if (moves[i] == LEFT) x--;
        else if (moves[i] == RIGHT) x++;

        // IJON annotation: tell AFL++ we're getting closer to goal
        __AFL_IJON_MAX(abs(x - goal_x) + abs(y - goal_y));
    }

    if (x == goal_x && y == goal_y) {
        trigger_vulnerability();  // Reachable with IJON guidance
    }
}
```

**Without IJON**: AFL++ blindly mutates `moves[]` with no feedback on progress.

**With IJON**: AFL++ sees distance decreasing, prioritizes inputs that reduce `__AFL_IJON_MAX()` value.

## Workflow

### 1. POI Selection ([Lines 274-278](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py#L274-L278))

**Input**: Report (SARIF, CodeSwipe, or patch)

```python
# Parse report and extract Points of Interest
poi_obj.add_poi(report_path)
if poi_obj.empty:
    raise ValueError("☣️ AIJON instrumentation failed since no POIs were found.")
```

**POI Types**:
- **SarifPOI**: From SARIF reports (CodeQL, Semgrep, CodeChecker)
- **CodeSwipePOI**: From CodeSwipe vulnerability reports
- **PatchPOI**: From patch/diff analysis

### 2. Coverage Analysis ([Lines 136-160](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py#L136-L160))

**Query Analysis Graph** to find paths to uncovered functions:

```python
# Check if sink function is covered by any harness
if not ag_utils.check_function_covered(sink_funcindex):
    # Find closest covered caller
    closest_covered_caller, call_path = ag_utils.find_closest_covered_caller(
        sink_funcindex=sink_funcindex
    )

    if not closest_covered_caller:
        # No covered caller found, find longest paths to sink
        logger.warning(
            f"🤡 Warning: No covered caller found for sink function {sink_funcindex}",
        )
        call_path = ag_utils.find_paths_to_sink(sink_funcindex)

        if len(call_path) == 0:
            logger.warning(
                f"🎪 Warning: No paths found to sink function {sink_funcindex}."
            )
            return

else:
    # Sink function is covered, use it directly
    closest_covered_caller, call_path = sink_funcindex, list()
```

**Purpose**: Identify which functions are already covered by fuzzers, and find call paths from covered functions to uncovered vulnerability sinks.

### 3. Harness and Seed Discovery ([Lines 162-168](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py#L162-L168))

```python
if closest_covered_caller:
    logger.debug(
        f"Finding harness name and inputs for function {closest_covered_caller}"
    )
    harness_input_dict.update(
        ag_utils.get_harness_name_and_inputs(closest_covered_caller)
    )
```

**Result**:
- **Harness name**: Which fuzzer harness covers the closest caller
- **Seed inputs**: Inputs that reach the closest caller (from HarnessInputNode in Neo4j)

### 4. LLM Instrumentation ([Lines 216-234](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py#L216-L234))

```python
# Step 3 is to instrument the code with IJON
try:
    logger.info(f"Instrumenting code @ {modified_source_dir} with POI {poi}")
    cost, llm_response = instrument_code_with_ijon(
        poi,
        resolved_sinkfunc_index,
        modified_source_dir,
    )
    total_cost += cost
    logger.debug(f"Cost of instrumenting code with IJON: {total_cost}")
except ValueError:
    logger.warning(
        f"🤡 Warning: Could not instrument code with IJON for POI {poi}. Skipping."
    )
    return
```

**`instrument_code_with_ijon`** (from `aijon_lib`):
1. Load function source code
2. Send to LLM with prompt: "Add IJON annotations to guide fuzzer toward this vulnerability"
3. LLM returns modified code with `__AFL_IJON_MAX()` calls
4. Return cost and LLM response

### 5. Code Patching ([Lines 298-329](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py#L298-L329))

**Apply LLM-generated instrumentation** to source files:

```python
for worker_data in sorted((r for r in results if r), key=lambda x: -x["function_line_number"]):
    filename = worker_data["filename"]
    function_line_number = worker_data["function_line_number"]
    llm_response = worker_data["llm_response"]

    try:
        target_file_path = modified_source_dir / filename
        original_code = target_file_path.read_text()

        modified_code, bad_blocks, num_success = apply_llm_response(
            original_code=original_code,
            llm_response=llm_response,
            line_offset=function_line_number-1,  # Adjust for 1-indexing
            language=os.getenv("LANGUAGE")
        )

        target_file_path.write_text(modified_code)
    except Exception as e:
        logger.warning(
            f"🤡 Search and replace failed for {filename}. {e} - Skipping."
        )
        continue

    global_allow_list_funcs.update(allow_list_funcs)
    global_harness_input_dict.update(harness_input_dict)
```

**Sorting**: Process functions from bottom to top (by line number descending) to avoid offset corruption when patching multiple functions in same file.

### 6. Output Generation ([Lines 425-471](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py#L425-L471))

**Three outputs**:

#### A. Instrumented Code
```python
if args.diff_only:
    # Generate patch file
    diff_contents = ag_utils.get_diff_contents(modified_source)
    diff_file = destination / "aijon_instrumentation.patch"
    diff_file.write_text(verified_diff)
else:
    # Copy full instrumented source
    shutil.copytree(modified_source, destination, dirs_exist_ok=True)
```

#### B. Function Allowlist ([Lines 444-448](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py#L444-L448))
```python
if len(allow_list_funcs) > 0:
    allowlist_file.write_text("\n".join(allow_list_funcs) + "\n")
    logger.success(
        f"📝 Allowlist file is saved to {allowlist_file} with {len(allow_list_funcs)} functions."
    )
```

**Purpose**: Tell AFL++ to preferentially instrument functions in call paths to vulnerabilities.

#### C. Seed Corpus ZIP ([Lines 450-471](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py#L450-L471))
```python
for harness_name in harness_input_dict:
    logger.info(
        f"Found {len(harness_input_dict[harness_name])} inputs for harness: {harness_name}"
    )
    input_file_dir = destination / harness_name
    input_file_dir.mkdir(parents=True, exist_ok=True)

    seed_corpus_file = destination / f"{harness_name}_seed_corpus.zip"
    with zipfile.ZipFile(seed_corpus_file, "w") as zipf:
        for idx, input_bytes in enumerate(harness_input_dict[harness_name]):
            input_file = input_file_dir / f"{idx}"
            input_file.write_bytes(input_bytes)
            zipf.write(input_file, arcname=input_file.name)

    shutil.rmtree(input_file_dir)
    logger.success(
        f"🎁 Seed corpus for harness {harness_name} is saved to {seed_corpus_file}."
    )
```

**Seeds**: Inputs that reach `closest_covered_caller`, providing starting point for fuzzer to explore paths to vulnerability.

## Parallel Execution

**Worker Pool** ([Lines 284-291](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py#L284-L291)):

```python
with Pool(processes=20) as pool:
    logger.info(
        f"Starting parallel processing of {len(poi_obj.get_all_pois())} POIs."
    )
    results = pool.starmap(
        worker_function,
        [(poi, modified_source_dir) for poi in poi_obj.get_all_pois()],
    )
```

**20 parallel workers** process POIs concurrently, each:
1. Querying Analysis Graph
2. Calling LLM for instrumentation
3. Collecting allowlist functions and seeds

## Retry Mechanism ([Lines 400-421](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aijon/main.py#L400-L421))

```python
ctr = 0
while True:
    if ctr == 10:
        raise RuntimeError("☣️ AIJON instrumentation failed 10 times.")

    with tracer.start_as_current_span("aijon.instrument"):
        try:
            modified_source, allow_list_funcs, harness_input_dict = main(
                target_source, report_path, POI_obj
            )
        except ValueError:
            logger.error("🤡 No POI's found. Exiting")
            raise RuntimeError(
                "☣️ AIJON instrumentation failed since no POIs were found."
            )

    if len(allow_list_funcs) > 0:
        break  # Success

    logger.warning("🫂 AIJON instrumentation failed. Retrying in 10 minutes.")
    POI_obj.remove_all_pois()
    time.sleep(600)  # 10-minute backoff
    ctr += 1
```

**Why retry**: LLM may fail to generate valid instrumentation. Retry with fresh POI parsing.

## Integration with AFL++

**Workflow**:
1. AIJON instruments source code
2. Build project with instrumented code
3. AFL++ compiles with IJON support (`AFL_USE_IJON=1`)
4. Fuzzer runs with seed corpus from AIJON
5. AFL++ prioritizes inputs that increase IJON counter values
6. Fuzzer explores paths toward vulnerabilities

## Related Components

- **[AFL++](../fuzzing/aflplusplus.md)**: Consumes IJON instrumentation
- **[Analysis Graph](../../infrastructure/analysis-graph.md)**: Provides coverage data
- **[CodeQL](../static-analysis/codeql.md)**: Generates SARIF reports for POI
- **[Vuln Detect Model](./vuln-detect-model.md)**: Identifies vulnerabilities for instrumentation
