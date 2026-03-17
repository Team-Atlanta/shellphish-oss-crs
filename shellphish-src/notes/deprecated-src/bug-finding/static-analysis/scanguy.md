# Scanguy

Scanguy is an in-house LLM-based vulnerability detection component that uses a custom fine-tuned model to identify CWE patterns in code. It analyzes functions reachable from fuzzing harnesses through a two-phase scan-and-validate approach, leveraging call graph context and semantic reasoning.

## Purpose

- AI-powered vulnerability detection using fine-tuned LLM
- Analyze functions reachable from fuzzing harnesses
- Detect CWE vulnerabilities with semantic understanding
- Provide reasoning and confidence scores for findings
- Support both full and delta (incremental) scanning modes

## Architecture

### Pipeline Tasks

**File**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/pipeline.yaml)

1. **`request_gpu_machine`** ([Lines 17-68](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/pipeline.yaml#L17-L68))
   - Reserves GPU node and waits for vLLM server availability
   - Polls model endpoint 200 times (20s intervals)
   - Node labels: `support.shellphish.net/only-gpu: true`

2. **`scan_guy_full`** ([Lines 70-145](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/pipeline.yaml#L70-L145))
   - Full scan of all reachable functions
   - Timeout: 30 minutes
   - Max concurrent jobs: 40
   - Priority: 100

3. **`scan_guy_delta`** ([Lines 147-222](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/pipeline.yaml#L147-L222))
   - Delta scan for incremental changes
   - Timeout: 15 minutes (half of full)
   - Same configuration as full scan

### Entry Point

**Main Script**: [`run.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/run.py)
- Sets up agentlib with $10 budget limit ([Lines 28-32](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/run.py#L28-L32))
- Enables event dumping to `/tmp/stats/`
- Delegates to `scanguy.main.main()`

## Core Implementation

### Main Workflow

**Class**: `ScanGuy` in [`main.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py)

**Initialization** ([Lines 44-97](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L44-L97)):
```python
class ScanGuy:
    def __init__(self):
        # Load project metadata
        self.metadata = AugmentedProjectMetadata.from_yaml(...)

        # Initialize function resolver (Local or Remote)
        self.func_resolver = LocalFunctionResolver(...) or \
                           RemoteFunctionResolver(...)

        # Initialize Neo4j analysis graph API
        self.analysis_graph_api = AnalysisGraphAPI(...)

        # Load LLM tool access (PeekSrcSkill)
        self.toolbox = PeekSrcSkill(self.func_resolver)
```

**Execution Flow** - `start()` method ([Lines 439-619](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L439-L619)):

1. **Fetch Entry Points** ([Lines 446-449](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L446-L449)):
   ```python
   # Find harness functions
   # C/C++: LLVMFuzzerTestOneInput
   # Java: fuzzerTestOneInput, @FuzzTest
   entry_points = self._fetch_sources()  # 5 retry attempts
   ```

2. **Build Call Graph Paths** ([Lines 454-468](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L454-L468)):
   ```python
   # Query Neo4j for all reachable functions within 10 hops
   sink_to_paths = self.analysis_graph_api.get_more_paths(entry_points)
   # Returns: {sink_function: [path1, path2, ...]}
   ```

3. **Deduplicate Sinks** ([Lines 470-482](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L470-L482)):
   ```python
   # Remove functions with identical code
   unique_sinks = deduplicate_by_code(sinks)

   # Filter to focus repository only
   focus_sinks = [s for s in unique_sinks if is_focus_repo(s)]
   ```

4. **Build Context Graphs** ([Lines 492-498](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L492-L498)):
   ```python
   # For each sink, merge all paths into NetworkX DiGraph
   for sink in focus_sinks:
       paths = sink_to_paths[sink]
       graph = nx.DiGraph()
       for path in paths:
           add_path_to_graph(graph, path)

       # Reduce cycles for topological ordering
       ordered_nodes, acyclic_graph = reduce_cycle(graph)
       sink_contexts[sink] = ordered_nodes
   ```

5. **Parallel Scanning** ([Lines 535-563](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L535-L563)):
   ```python
   with ThreadPoolExecutor(max_workers=100) as executor:
       futures = [
           executor.submit(self._scan_worker, sink_key)
           for sink_key in focus_sinks
       ]

       scan_results = []
       for i, future in enumerate(as_completed(futures)):
           result = future.result()
           scan_results.append(result)

           # Save every 100 functions
           if i % 100 == 0:
               save_json(scan_results, "scan_results.json")
   ```

6. **Validation Phase** ([Lines 567-618](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L567-L618)):
   ```python
   # Filter for predicted vulnerabilities
   vulnerable = [r for r in scan_results
                 if r["predicted_is_vulnerable"] == "yes"]

   # Parallel validation
   with ThreadPoolExecutor(max_workers=100) as executor:
       futures = [
           executor.submit(self._validate_worker, result)
           for result in vulnerable
       ]

       validate_results = [f.result() for f in as_completed(futures)]

   save_json(validate_results, "validate_results.json")
   ```

### Scan Worker

**Method**: `_scan_worker()` ([Lines 310-333](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L310-L333))

```python
def _scan_worker(self, sink_index_key):
    # 1. Get function info
    func_info = self.func_resolver.get(sink_index_key)  # 5 retries
    func_code = self.func_resolver.get_code(sink_index_key)

    # 2. Build node context from call graph
    context_nodes = self.sink_contexts[sink_index_key]
    caller_code = [get_code(node) for node in reversed(context_nodes)]

    # 3. Create HongweiScan agent
    agent = HongweiScan(
        CODE=func_code,
        NODES=caller_code,
        CWE_PROMPT=get_cwe_prompt(language),
        toolbox=self.toolbox
    )

    # 4. Execute scan with retry logic
    output = run_scan(agent)

    # 5. Return structured result
    return {
        "function": func_info.funcname,
        "file": func_info.filename,
        "function_index_key": sink_index_key,
        "output": output,
        "predicted_is_vulnerable": extract_judgment(output),
        "predicted_vulnerability_type": extract_cwe_type(output)
    }
```

### Validate Worker

**Method**: `_validate_worker()` ([Lines 336-375](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L336-L375))

```python
def _validate_worker(self, scan_result):
    # 1. Get function code (with retries)
    func_code = self.func_resolver.get_code(
        scan_result["function_index_key"]
    )

    # 2. Extract reasoning from scan
    reasoning = extract_reasoning(scan_result["output"])

    # 3. Create HongweiValidate agent
    agent = HongweiValidate(
        CODE=func_code,
        NODES=caller_code,  # Same context as scan
        REASONING=reasoning,  # Initial scan reasoning
        CWE_PROMPT=get_cwe_prompt(language),
        toolbox=self.toolbox
    )

    # 4. Execute validation
    output = run_validate(agent)

    # 5. Return refined assessment
    return {
        **scan_result,
        "validate_output": output,
        "validate_is_vulnerable": extract_judgment(output),
        "validate_vulnerability_type": extract_cwe_type(output)
    }
```

## LLM Agent Architecture

### Model Configuration

**Custom Fine-Tuned Model**:
- Model: `best_n_no_rationale_poc_agent_withjava_final_model_agent_h100`
- Hosted on: vLLM server at `http://vllm-server:25002/v1`
- Serving: [`serve_model.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/serve_model.sh)
  ```bash
  CUDA_VISIBLE_DEVICES=4,5,6,7 vllm serve \
    secmlr/best_n_no_rationale_poc_agent_withjava_final_model_agent_h100 \
    --dtype=bfloat16 \
    --tensor-parallel-size=4 \
    --port 25002 \
    --max-tokens=2000
  ```

### HongweiScan Agent

**File**: [`HongweiScan.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/agents/HongweiScan.py)

**Configuration** ([Lines 70-88](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/agents/HongweiScan.py#L70-L88)):
- Base class: `AgentWithHistory[dict, str]`
- Max tool iterations: 5
- Retries on validation error: 3
- Context window strategy: throw_exception

**Input Structure** ([Line 113](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/agents/HongweiScan.py#L113)):
```
<context>
[Caller functions code - up to 30KB total]
</context>
<target_function>
[Target function to analyze]
</target_function>
```

**Context Limit** ([Lines 102-113](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/agents/HongweiScan.py#L102-L113)):
```python
max_len = 30000  # 30KB
selected_nodes = []
cur_len = 0

for node in reversed(NODES):  # Most recent callers first
    if len(node['code']) + cur_len < max_len:
        selected_nodes.append(node)
        cur_len += len(node['code'])
    else:
        break
```

**Available Tool** ([Line 126](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/agents/HongweiScan.py#L126)):
- `get_function_definition(func_name)`: Retrieve any function's implementation

**System Prompt Template**: [`prompts/HongweiScan/system.j2`](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/scanguy/src/scanguy/agents/prompts/HongweiScan)
- Instructs model to detect vulnerabilities in target function only
- Requires reasoning about execution paths and crash locations
- Must analyze each provided CWE pattern
- Mandates tool usage: "at least twice, at most three times"

**Output Format** ([`HongweiScan.output.txt`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/agents/prompts/HongweiScan/HongweiScan.output.txt)):
```
<reasoning_process>Detailed analysis...</reasoning_process>
<vuln_detect>
## Final Answer
#judge: yes/no
#type: CWE-XXX or N/A
</vuln_detect>
```

### HongweiValidate Agent

**File**: [`HongweiValidate.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/agents/HongweiValidate.py)

**Key Differences from Scan**:
- Context window: 50KB (vs 30KB) ([Line 103](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/agents/HongweiValidate.py#L103))
- Receives initial reasoning from scan phase
- System prompt focuses on validating assumptions
- Must report "only the most probable CWE"

### Execution with Retry Logic

**Function**: `run_scan()` ([Lines 181-243](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L181-L243))

```python
def run_scan(agent):
    RETRY_LIMIT = 3

    for attempt in range(RETRY_LIMIT):
        try:
            # 1. Invoke agent
            response = agent.run()

            # 2. Validate output format
            if not has_reasoning_and_vuln_detect(response):
                if attempt < RETRY_LIMIT - 1:
                    # Augment prompt with format reminder
                    agent.add_format_reminder()
                    continue
                else:
                    return response  # Give up after retries

            # 3. Parse and return
            return response

        except ContextWindowExceededError:
            # Trim message history
            agent.trim_history()
            response = agent.invoke_llm_directly()
            return response

        except MaxIterationsReached:
            # Extract conversation and parse
            conversation = agent.get_conversation_history()
            response = agent.invoke_llm_on_conversation(conversation)
            return parse_vuln_scan_output(response)

    return "INVALID FORMAT AFTER RETRIES"
```

**Output Parsing** ([Lines 144-179](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L144-L179)):
```python
def parse_vuln_scan_output(output):
    # Extract reasoning section
    reasoning_match = re.search(
        r'<reasoning_process>(.*?)</reasoning_process>',
        output,
        re.DOTALL
    )

    # Extract vuln_detect section
    vuln_match = re.search(
        r'<vuln_detect>(.*?)</vuln_detect>',
        output,
        re.DOTALL
    )

    # Parse judge: yes/no
    judge_match = re.search(r'#judge:\s*(yes|no)', vuln_text, re.I)

    # Parse type: CWE-XX
    type_match = re.search(r'#type:\s*(CWE-\d+|N/A)', vuln_text, re.I)

    return {
        "reasoning": reasoning_text,
        "judge": judge_text,
        "type": type_text
    }
```

## CWE Coverage

### C/C++ CWEs ([Lines 415-419](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L415-L419))
- CWE-119: Buffer boundary operations
- CWE-416: Use After Free
- CWE-476: NULL Pointer Dereference

### Java/Other CWEs ([Lines 421-435](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L421-L435))
- CWE-74: Injection
- CWE-22: Path Traversal
- CWE-918: SSRF
- CWE-502: Deserialization
- CWE-917: Expression Language Injection
- CWE-90: LDAP Injection
- CWE-154: Variable Name Delimiters
- CWE-470: Unsafe Reflection
- CWE-777: Regex without Anchors
- CWE-89: SQL Injection
- CWE-643: XPath Injection
- CWE-611: XXE
- CWE-835: Infinite Loop

## Toolbox Integration

**File**: [`toolbox/peek_src.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/toolbox/peek_src.py)

**PeekSrcSkill Class** - LLM-Accessible Tools:

1. **`get_function_definition(func_name)`** ([Lines 85-94](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/toolbox/peek_src.py#L85-L94)):
   - Primary tool for agents
   - Resolves function by name via function resolver
   - Returns concatenated definitions if multiple matches
   - Handles class methods (strips class prefix)

2. **`lookup_symbol(expression)`** ([Lines 100-120](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/toolbox/peek_src.py#L100-L120)):
   - Grep-based code search
   - POSIX ERE regex support
   - Returns matching lines across project

3. **`search_function(func_name)`** ([Lines 73-82](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/toolbox/peek_src.py#L73-L82)):
   - Find function locations
   - Returns file and line numbers

4. **`show_file_at(file_path, offset, num_lines)`** ([Lines 49-69](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/toolbox/peek_src.py#L49-L69)):
   - Display file contents
   - Max 100 lines per view
   - Line-numbered output

**Tool Guards**:
- Duplicate call detection (tracks last 3 calls)
- Prevents infinite loops in LLM tool usage

## Analysis Graph Integration

**File**: [`analysis_graph_api.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/analysis_graph_api.py)

**Neo4j Query** - `get_more_paths()` ([Lines 289-317](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/analysis_graph_api.py#L289-L317)):
```cypher
MATCH (start:CFGFunction)
WHERE ANY(prefix IN $entry_points
          WHERE start.identifier CONTAINS prefix)

CALL apoc.path.spanningTree(start, {
    relationshipFilter: 'DIRECTLY_CALLS|MAYBE_INDIRECT_CALLS>',
    maxLevel: 10
}) YIELD path

WITH collect(DISTINCT last(nodes(path))) AS sink_nodes, start
UNWIND sink_nodes AS sink

MATCH p = allShortestPaths(
    (start)-[:DIRECTLY_CALLS|MAYBE_INDIRECT_CALLS*..10]->(sink)
)

RETURN sink.identifier AS sink_funcindex,
       [node IN nodes(p) | node.identifier] AS path
```

**Path Types**:
- `DIRECTLY_CALLS`: Definite call relationships
- `MAYBE_INDIRECT_CALLS`: Potential indirect calls
- Max depth: 10 hops from harness

## Graph Processing

### Cycle Reduction

**Function**: [`reduce_cycle()`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/utils.py#L579-L592) in `utils.py`

```python
def reduce_cycle(G):
    if nx.is_directed_acyclic_graph(G):
        nodes = list(nx.topological_sort(G))
    else:
        # Remove edges to break cycles
        while True:
            try:
                cycle = nx.find_cycle(G)
                G.remove_edge(*cycle[0])
            except nx.NetworkXNoCycle:
                break
        nodes = list(nx.topological_sort(G))

    return nodes, G
```

### Context Building

**Method**: [`_build_node_context()`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/scanguy/main.py#L99-L142)
- Merges multiple paths to same sink
- Creates NetworkX DiGraph from Neo4j paths
- Reduces cycles for topological ordering
- Extracts caller code for context

## Output Formats

### Scan Results

**File**: `scan_results.json`
```json
[
  {
    "function": "vulnerable_func",
    "file": "/src/path/to/file.c",
    "function_index_key": "key_string",
    "output": "<reasoning_process>...</reasoning_process><vuln_detect>...</vuln_detect>",
    "predicted_is_vulnerable": "yes|no|invalid format",
    "predicted_vulnerability_type": "CWE-XXX|N/A"
  }
]
```

### Validation Results

**File**: `validate_results.json`
- Same format as scan results
- Only contains functions marked vulnerable in scan phase
- Additional fields: `validate_output`, `validate_is_vulnerable`, `validate_vulnerability_type`

## Resource Management

### GPU Configuration

**Node Selection** ([Lines 24-29](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/pipeline.yaml#L24-L29)):
```yaml
node_labels:
  "support.shellphish.net/only-gpu": "true"
node_taints:
  "support.shellphish.net/only-gpu": "true"
node_affinity:
  "support.shellphish.net/only-gpu": "true"
```

### Budget Control

**From** [`run.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/scanguy/src/run.py#L29-L32):
```python
agentlib.set_global_budget_limit(
    price_in_dollars=Config.scanguy_budget_limit,  # $10
    exit_on_over_budget=True,
)
```

### Concurrency

- Max concurrent jobs: 40 (pipeline level)
- Thread pool workers: 100 (application level)
- Parallel scan and validate phases

## Error Handling

**Result States**:
1. `predicted_is_vulnerable: "yes"` - Vulnerability detected
2. `predicted_is_vulnerable: "no"` - No vulnerability
3. `predicted_is_vulnerable: "invalid format"` - Parse failure
4. Special outputs:
   - "INPUT EXCEEDS CONTEXT WINDOW"
   - "Agent stopped due to max iterations."

**Resilience Features**:
- 5 retries for function resolver operations
- 5 retries for Neo4j queries with 30s delays
- 3 retries for LLM format errors
- Graceful degradation on individual function failures

## Dependencies

**Upstream**:
- **Function Index Generator**: Provides function resolution
- **CodeQL**: Provides call graph in Neo4j
- **Clang Indexer**: Provides function metadata

**Downstream**:
- **Patch Generation**: Uses findings for targeted patching
- **Vulnerability Aggregation**: Combined with other static analysis results

## Related Components

- **[CodeQL](./codeql.md)**: Provides call graph for context
- **[Function Index Generator](./function-index-generator.md)**: Provides function resolution
- **[Clang Indexer](./clang-indexer.md)**: Provides function metadata
