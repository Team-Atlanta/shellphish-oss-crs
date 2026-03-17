# PatcherQ (Queue)

PatcherQ is the **LLM-driven patch generation engine** that generates source-level patches from POI reports, SARIF reports, or refinement requests. It uses a multi-agent architecture with ProgrammerGuy (patch generator), CriticGuy (patch validator), and TriageGuy (root cause analyzer).

## Purpose

- LLM-based patch generation with Claude 3.7 Sonnet
- Multi-mode operation (PATCH, REFINE, SARIF)
- Root cause analysis integration (DyVA, Triage, SARIF)
- CodeQL server integration for dataflow analysis
- Multi-run verification with feedback loops
- Delta mode for focused patching on changed functions
- Greedy vs exhaustive patching strategies

## Implementation

**Main File**: [`main.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/main.py)

**Agent**: [`programmerGuy.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/programmerGuy.py)

**Pipeline**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/pipeline.yaml)

## Three Modes

### PATCH Mode ([run.py Lines 79-96](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/run.py#L79-L96))

**Generate initial patch from POI report**.

```python
if args.patcherq_mode == "PATCH":
    Config.patcherq_mode = PatcherqMode.PATCH

    # Load POI report
    with open(args.poi_report, 'r') as f:
        poi_report = yaml.load(f, Loader=yaml.FullLoader)

    sanitizer_to_build_with = poi_report['sanitizer']

    # Load patch request metadata
    with open(args.patch_request_meta, 'r') as f:
        patch_request_meta = PatchRequestMeta.model_validate(yaml.safe_load(f))

    # Validate
    assert patch_request_meta.request_type == "patch"
    assert patch_request_meta.patch_id == None  # New patch
    assert patch_request_meta.poi_report_id == args.poi_report_id
```

**Input**: POI report with crash site, stack traces, and context.

**Output**: Fresh patch attempt.

### REFINE Mode ([Lines 107-126](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/run.py#L107-L126))

**Refine existing patch to fix new bypassing POV**.

```python
elif args.patcherq_mode == "REFINE":
    Config.patcherq_mode = PatcherqMode.REFINE

    # Load POI report for new bypassing POV
    with open(args.poi_report, 'r') as f:
        poi_report = yaml.load(f, Loader=yaml.FullLoader)

    sanitizer_to_build_with = poi_report['sanitizer']

    # Load patch request metadata
    with open(args.patch_request_meta, 'r') as f:
        patch_request_meta = PatchRequestMeta.model_validate(yaml.safe_load(f))

    # Validate
    assert patch_request_meta.request_type == "refine"
    assert patch_request_meta.patch_id != None  # Refining existing patch
    assert patch_request_meta.poi_report_id == args.poi_report_id
```

**Input**: Failing patch + new bypassing POV.

**Output**: Refined patch that fixes both old and new POVs.

### SARIF Mode ([Lines 98-105](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/run.py#L98-L105))

**Generate patches from static analysis reports** (currently disabled in production).

```python
elif args.patcherq_mode == "SARIF":
    Config.patcherq_mode = PatcherqMode.SARIF

    # Load SARIF report
    with open(args.project_metadata, 'r') as f:
        project_yaml = AugmentedProjectMetadata.model_validate(yaml.safe_load(f))

    sanitizer_to_build_with = project_yaml.sanitizers[0]
```

**Note**: Lines 426-430 in pipeline.yaml show SARIF mode is disabled in production (`exit 1`).

## Core Loop ([main.py Lines 69-194](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/main.py#L69-L194))

```python
def start(self):
    # Generate initial context report
    if Config.patcherq_mode in (PatcherqMode.PATCH, PatcherqMode.REFINE):
        self.poi_report, self.poi_report_meta, self.issue_ticket, \
        self.initial_context_report, self.funcs_in_scope = \
            Helper.get_initial_context_report(patcherq=self)

    root_cause_reports = set()
    successful_patch_attempts = dict()
    patch_generator = PatchGenerator(self.cp, self.func_resolver, self.kwargs)

    # 🔄💰 Budget recovery loop
    while True:

        # 🔄📜 Iterate over root cause reports (DyVA, Triage, etc.)
        for root_cause_report_id, root_cause_report in enumerate(self.root_cause_generator.reports()):
            if not root_cause_report:
                continue

            root_cause_reports.add(root_cause_report)

            # Create programmer agent
            programmer = Programmer(
                patcherq=self,
                root_cause_report_id=root_cause_report_id,
                root_cause_report=root_cause_report,
                patch_generator=patch_generator,
                successful_patch_attempts=successful_patch_attempts,
                sanitizers=self.poi_report_meta.consistent_sanitizers,
            )

            # Feedback loop: generate → verify → refine
            while programmer.patch_state != 'stop':
                programmer.generate()  # LLM generates patch
                if programmer.patch_state == "giveup":
                    break  # MaxToolCalls or unrecoverable error
                if programmer.patch_state == 'success':
                    patched_cp = programmer.verify()  # Verify patch

            # Save successful patch
            if programmer.patch_verified:
                programmer.save(patched_cp=patched_cp)

            # Greedy patching: stop at first success
            if Config.greedy_patching and len(successful_patch_attempts) > 0:
                break

        ############ End root cause loop ############

        # No successful patch? Check if we should wait for missing reports
        if len(successful_patch_attempts) == 0:
            if self.root_cause_generator.check_missing_reports():
                if Config.nap_mode and self.root_cause_generator.how_many_naps < Config.nap_becomes_death_after:
                    self.root_cause_generator.take_a_nap()  # Wait for DyVA/Triage
                else:
                    break  # Give up
            else:
                break  # No missing reports, give up
        else:
            # Have successful patch, check if we want more
            if self.root_cause_generator.check_missing_reports():
                if Config.greedy_patching:
                    break  # Don't wait for more reports
                else:
                    continue  # Wait for more reports to get more patches
            else:
                break  # No missing reports, done

    ############ End budget loop ############

    # Save successful patches
    if len(successful_patch_attempts) > 0:
        exit(0)  # Success
    else:
        exit(1)  # Failure
```

**Nested Loops**:
1. **Budget loop** (🔄💰): Retries on LLM budget exceptions
2. **Root cause loop** (🔄📜): Iterates over DyVA, Triage, SARIF reports
3. **Feedback loop**: generate → verify → refine until success or giveup

## ProgrammerGuy Agent ([programmerGuy.py Lines 179-418](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/programmerGuy.py#L179-418))

```python
class ProgrammerGuy(AgentWithHistory[dict,str]):
    __LLM_MODEL__ = 'claude-3.7-sonnet'

    __SYSTEM_PROMPT_TEMPLATE__ = '/src/patcherq/prompts/programmerGuy/programmerGuy.CoT.system.j2'
    __USER_PROMPT_TEMPLATE__ = '/src/patcherq/prompts/programmerGuy/programmerGuy.CoT.user.j2'
    __MAX_TOOL_ITERATIONS__ = 70

    __LLM_ARGS__ = {
        'temperature': 0.0,
        'max_tokens': 8192
    }

    # Template variables
    ROOT_CAUSE_REPORT: Optional[str]
    LANGUAGE_EXPERTISE: Optional[str]

    # Feedback loop variables
    IS_FEEDBACK: Optional[bool]
    FAILURE: Optional[str]
    FEEDBACK_WHY_PREVIOUS_PATCH_FAILED: Optional[str]
    WITH_PATCHES_ATTEMPT: Optional[str]
    FAILED_PATCHES_ATTEMPT: Optional[str]
    EXTRA_FEEDBACK_INSTRUCTIONS: Optional[str]
    REFINE_JOB: Optional[str]
    FAILED_FUNCTIONALITY: Optional[str]
    NUM_CRASHING_INPUTS_TO_PASS: Optional[str]
    WITH_HINTS: Optional[str]
    DELTA_HINTS: Optional[str]
```

**Tools Available** ([Lines 376-415](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/programmerGuy.py#L376-L415)):

```python
def get_available_tools(self):
    my_tools = []

    if self.IS_FEEDBACK:
        # Failure-specific tools
        if self.FAILURE == FailureCodes.PATCHED_CODE_STILL_CRASHES:
            my_tools.extend(TOOLS.values())  # show_file_at, get_functions_by_file, etc.
        elif self.FAILURE == FailureCodes.PATCHED_CODE_HANGS:
            my_tools.extend(TOOLS_WITH_LOGS.values())  # show_log_at, search_string_in_log
        elif self.FAILURE == FailureCodes.PATCHED_CODE_DOES_NOT_COMPILE:
            my_tools.extend(TOOLS_WITH_LOGS.values())
        elif self.FAILURE == FailureCodes.PATCHED_CODE_DOES_NOT_PASS_TESTS:
            my_tools.extend(TOOLS_WITH_LOGS.values())
        # ... more failure codes
    else:
        my_tools.extend(TOOLS.values())

    if self.with_lang_server:
        my_tools.extend(LANG_SERVER_TOOLS.values())  # LSP tools

    if self.with_codeql_server:
        my_tools.extend(CODEQL_TOOLS.values())  # CodeQL dataflow queries

    return my_tools
```

**Available Tools**:
- **Code Navigation**: `show_file_at`, `get_functions_by_file`, `search_string_in_file`, `get_function_or_struct_location`
- **Log Analysis** (for failures): `show_log_at`, `search_string_in_log`
- **Language Server** (optional): LSP queries for call graphs, type info
- **CodeQL** (optional): Dataflow analysis, taint tracking

## Patch Format ([programmerGuy.py Lines 100-152](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/programmerGuy.py#L100-L152))

```python
def extract_changes(self, text: str):
    # Find all <change> elements with regex
    changes = re.findall(
        r'<change>\s*'
        r'<file>(.*?)</file>\s*'
        r'<line>\s*<start>(.*?)</start>\s*<end>(.*?)</end>\s*</line>\s*'
        r'<original>([\s\S]*?)</original>\s*'
        r'<patched>([\s\S]*?)</patched>\s*'
        r'</change>',
        text, re.DOTALL
    )

    if len(changes) == 0:
        # Try to fix format with LLM
        text = self.fix_patch_format(text)

    return changes

def extract_patch(self, text: str):
    changes = self.extract_changes(text)
    patch = []
    for file_path, start_loc, end_loc, original_code, patched_code in changes:
        parsed_change = {
            "change_id": int(change_id),
            "file": file_path.strip(),
            "line": {
                "start": int(start_loc.strip()),
                "end": int(end_loc.strip())
            },
            "original": original_code,
            "patched": patched_code
        }
        patch.append(parsed_change)
    return patch
```

**Expected Format**:
```xml
<patch_report>
<change>
<file>src/foo.c</file>
<line><start>42</start><end>42</end></line>
<original>memcpy(stack_buf, buf, len);</original>
<patched>memcpy(stack_buf, buf, min(len, sizeof(stack_buf)));</patched>
</change>
</patch_report>
```

**Recovery**: If parsing fails, LLM attempts to fix format (up to 3 attempts).

## Verification Passes

PatcherQ uses multiple verification passes before accepting a patch:

1. **CompilePass**: Verify patch compiles
2. **BuildCheckPass**: Run build checks
3. **TestsPass**: Run project tests
4. **CrashPass**: Verify patch fixes crash
5. **CriticPass**: LLM reviews patch for correctness
6. **RegPass**: Regression testing against other POVs
7. **FuzzPass**: Short fuzzing campaign

**Feedback Loop**: If any pass fails, provide feedback to ProgrammerGuy for refinement.

## Root Cause Sources

PatcherQ collects root cause information from multiple sources:

### 1. DyVA Report ([main.py Lines 228-292](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/main.py#L228-L292))

```python
if Config.patcherq_mode == PatcherqMode.REFINE:
    # Fetch failing patch from Analysis Graph
    failing_patch_key = kwargs['failing_patch_id']
    failing_patch_info = Helper.get_failing_patch_info(failing_patch_key)
    failing_patch_node = failing_patch_info[0][0]
    failing_patch = FailedPatch(key=failing_patch_node.patch_key, diff=failing_patch_node.diff)

    # Fetch all crashing inputs from bucket
    crashing_input_nodes = Helper.get_crashing_inputs_from_bucket(kwargs['bucket_id'])
    for crashing_input_node in crashing_input_nodes:
        ci = CrashingInput(
            crashing_input_hex=crashing_input_node[0].content_hex,
            crashing_input_hash=crashing_input_node[0].content_hash
        )
        crashing_inputs.append(ci)

    # Add new crashing input
    with open(kwargs['crashing_input_path'], 'rb') as file:
        crash_input_bytes = file.read()
        crash_input_hex = crash_input_bytes.hex()
        ci = CrashingInput(crashing_input_hex=crash_input_hex, crashing_input_hash=hashlib.sha256(crash_input_bytes).hexdigest())
        crashing_inputs.append(ci)
```

**REFINE Mode**: Collects all crashing inputs in bucket for multi-POV patching.

### 2. Triage Agent

**Lightweight triage** for quick root cause identification.

### 3. SARIF Reports

**Static analysis findings** from CodeQL, Semgrep, CodeChecker.

## Delta Mode

**Purpose**: Focus patching on functions changed in recent commit.

**Configuration** ([pipeline.yaml Lines 641-659](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/pipeline.yaml#L641-L659)):

```yaml
export DIFF_FILE={{ crs_task_diff | shquote }}
export CHANGED_FUNCTIONS_INDEX={{ commit_functions_index | shquote }}
export CHANGED_FUNCTIONS_JSONS_DIR={{ commit_functions_jsons_dir | shquote }}

export CRS_MODE="delta"
```

**Hints** ([programmerGuy.py Lines 262-272](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/programmerGuy.py#L262-L272)):

```python
def get_hints_for_delta(self, funcs_in_scope: Set[FUNCTION_INDEX_KEY]) -> str:
    if not funcs_in_scope or not (Config.crs_mode == CRSMode.DELTA):
        return ""

    DELTA_HINT = ""
    for func in funcs_in_scope:
        func_diff = get_diff_snippet(func)
        if func_diff:
            DELTA_HINT += f"{func_diff}\n"

    return DELTA_HINT
```

**Delta Hints**: Provides diff snippets for changed functions to guide LLM toward regression-related patches.

## Sanitizer Hints ([Lines 274-294](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/programmerGuy.py#L274-L294))

```python
def get_hints_for_sanitizers(self, sanitizers: List[str]) -> str:
    all_hints = []

    with open("/src/patcherq/prompts/programmerGuy/extras/hints.json", "r") as f:
        human_hints = json.load(f)

    human_hints_for_language = human_hints.get(self.project_language, None)

    for sanitizer_triggered in sanitizers:
        for k, hint in human_hints_for_language.items():
            if k.lower() in sanitizer_triggered.lower():
                all_hints.append(hint)

    the_actual_hints = ''
    for i, hint in enumerate(all_hints):
        the_actual_hints += f"Hint {i+1}: {hint}\n"

    return the_actual_hints if len(the_actual_hints) > 0 else None
```

**Hints**: Language-specific hints for common sanitizer errors (e.g., "heap-buffer-overflow" → "Check array bounds").

## Pipeline Configuration

### Full Mode ([pipeline.yaml Lines 44-259](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/pipeline.yaml#L44-L259))

```yaml
patcherq:
  priority: 1000000
  job_quota:
    cpu: 2
    mem: "8Gi"
  max_concurrent_jobs: 16
  priority_function: "harness_queue"

  node_labels:
    support.shellphish.net/allow-patching: "true"
  node_taints:
    support.shellphish.net/only-patching: "true"

  links:
    patch_request_meta:
      repo: patch_requests_meta
      kind: InputFilepath

    poi_report:
      repo: points_of_interest
      kind: InputFilepath
      key: patch_request_metadata.poi_report_id

    crashing_input_path:
      repo: dedup_pov_report_representative_crashing_inputs
      kind: InputFilepath
      key: patch_request_metadata.poi_report_id

    dyva_report:
      repo: dyva_reports
      kind: InputFilepath

    codeql_db_ready:
      repo: codeql_db_ready
      kind: InputFilepath
```

### Delta Mode ([Lines 441-681](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/pipeline.yaml#L441-L681))

```yaml
patcherq_delta:
  priority: 1000000
  job_quota:
    cpu: 2
    mem: "8Gi"
  max_concurrent_jobs: 16

  links:
    crs_task_diff:
      repo: crs_tasks_diffs
      kind: InputFilepath
      key: poi_report_meta.project_id

    commit_functions_index:
      repo: commit_functions_indices
      kind: InputFilepath
      key: poi_report_meta.project_id

    commit_functions_jsons_dir:
      repo: commit_functions_jsons_dirs
      kind: InputFilepath
      key: poi_report_meta.project_id
```

## Performance Characteristics

- **LLM**: Claude 3.7 Sonnet (temperature=0.0)
- **Max tool calls**: 70 per agent invocation
- **Max tokens**: 8192
- **Resources**: 2 CPUs, 8GB RAM
- **Max concurrent**: 16 jobs
- **Priority**: `harness_queue` (by harness backlog)
- **Timeout**: Variable (up to 180 minutes)

## Configuration Flags

```python
class Config:
    patcherq_mode: PatcherqMode  # PATCH, REFINE, SARIF
    crs_mode: CRSMode  # full, delta

    greedy_patching: bool = True  # Stop at first success
    nap_mode: bool = True  # Wait for missing root cause reports
    nap_becomes_death_after: int = 3  # Max naps before giving up

    use_reg_pass: bool = True  # Regression testing
    use_codeql_server: bool = False  # CodeQL integration
    generate_sarif: bool = True  # Generate SARIF output

    emit_patched_artifacts: bool = True  # Upload patch artifacts
```

## Related Components

- **[PatcherG](./patcherg.md)**: Generates patch/refine/bypass requests
- **[PatcherY](./patchery.md)**: Source-level patch application
- **[DyVA](../bug-finding/vuln-detection/dyva.md)**: Provides root cause reports
- **[CodeQL](../bug-finding/static-analysis/codeql.md)**: Provides SARIF reports
- **[Analysis Graph](../infrastructure/analysis-graph.md)**: Stores patch state
