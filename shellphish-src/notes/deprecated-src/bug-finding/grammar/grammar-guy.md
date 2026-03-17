# Grammar-Guy

Grammar-Guy is an **in-house AI-driven grammar generation system** that creates and refines context-free grammars for fuzzing based on coverage feedback. It uses LLM-powered agents to iteratively improve grammars, targeting uncovered code and vulnerable functions.

## Purpose

- Coverage-guided grammar generation and refinement
- AI agent-based exploration for grammar improvement
- Create Nautilus-format grammars for AFL++/Jazzer
- Target specific functions or vulnerabilities
- Support delta mode for commit-specific fuzzing

## Architecture

### Pipeline Configuration

**File**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/pipeline.yaml)

**Key Tasks**:
1. **`grammar_guy_fuzz`** ([Lines 32-153](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/pipeline.yaml#L32-L153)) - Main grammar inference
2. **`grammar_agent_explore`** ([Lines 155-274](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/pipeline.yaml#L155-L274)) - Targeted exploration with AI agent
3. **`grammar_agent_explore_delta`** ([Lines 276-410](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/pipeline.yaml#L276-L410)) - Delta mode for commits
4. **`grammar_agent_reproduce_losan_dedup_pov`** ([Lines 411-526](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/pipeline.yaml#L411-L526)) - POV reproduction

### Source Structure

**Location**: [`src/grammar_guy/`](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/grammar-guy/src/grammar_guy)

**Key Files**:
- **grammar-guy.py**: Main functionality
- **config.py**: Pipeline handling
- **utils.py**: Token management, grammar splitting

## Implementation

### Main Workflow

**Entry Point**: `grammar_guy_fuzz` task

**Execution** ([pipeline.yaml Lines 89-101](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/pipeline.yaml#L89-L101)):
```bash
python /grammar-guy/grammar-guy.py \
  --mode inference \
  --functions-json-dir {{ full_functions_jsons_dirs }} \
  --function-indices {{ full_functions_indices }} \
  --output-dir {{ grammar_output }}
```

### Operational Modes

**1. Inference Mode** (`grammar_guy_fuzz`):
- Analyzes functions to infer input structure
- Generates initial context-free grammars
- Uses LLM to understand parsing logic
- Output: Nautilus RON format grammars

**2. Exploration Mode** (`grammar_agent_explore`):
- AI agent iteratively refines grammars
- Uses coverage feedback from coverage-guy
- Targets uncovered functions/blocks
- Budget: $10 per task ([README](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/README.md))

**3. Delta Mode** (`grammar_agent_explore_delta`):
- Focuses on changed functions in commits
- Uses `commit_functions_indices` instead of full indices
- Faster grammar generation for PR/commit testing
- Prioritizes vulnerability-prone changes

**4. Reproduction Mode** (`grammar_agent_reproduce_losan_dedup_pov`):
- Validates POVs for LOSAN bugs
- Creates grammars that reproduce specific inputs
- Used for semantic bug verification

### Coverage-Guided Refinement

**Feedback Loop** ([Lines 155-274](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/pipeline.yaml#L155-274)):

1. **Get Coverage Data**:
   - Queries coverage-guy for uncovered functions
   - Identifies coverage gaps

2. **Generate Targeted Grammar**:
   - AI agent analyzes uncovered function code
   - Creates grammar rules to reach target
   - Validates grammar produces parseable inputs

3. **Deploy Grammar**:
   - Writes to fuzzer sync directories
   - AFL++/Jazzer pick up new grammar

4. **Monitor Coverage**:
   - Coverage-guy tracks improvement
   - Repeat until coverage plateaus

### AI Agent Architecture

**Agent-Based Exploration**:
- LLM analyzes function code and control flow
- Generates grammar hypotheses
- Tests grammars against coverage metrics
- Iteratively refines based on results

**Token Management** ([utils.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/src/grammar_guy/utils.py)):
- Splits large functions to fit LLM context
- Manages token budgets to avoid exceeding limits
- Prioritizes critical code sections

**Grammar Splitting**:
- Breaks complex grammars into modular fragments
- Enables parallel generation
- Easier debugging and refinement

## Dependencies

### Upstream

**coverage-guy**: Provides coverage feedback
- Reachability information
- Uncovered function lists
- Coverage deltas

**coveragelib**: Coverage data processing
- Parses coverage reports
- Computes coverage metrics

**clang-indexer**: Function metadata
- Function code and signatures
- Call graphs

**fuzz-requestor**: Task orchestration
- Coordinates grammar deployment
- Manages fuzzer instances

### Downstream

**AFL++**: Nautilus grammar support
- Grammars placed in `/shellphish/libs/nautilus/grammars/`
- AFL++ flag: `-g 1000` enables grammar mutations

**Jazzer**: Java-specific grammars
- Similar Nautilus integration
- Grammar-guided JVM fuzzing

## Output Formats

### Nautilus RON Grammar

**Format**: Rusty Object Notation

**Example**:
```ron
grammar({
    "start": [
        "{header}{body}{footer}"
    ],
    "header": [
        "GET /",
        "POST /"
    ],
    "body": [
        "{path} HTTP/1.1\r\n",
        "{path}?{params} HTTP/1.1\r\n"
    ],
    "path": [
        "/index.html",
        "/api/{endpoint}"
    ]
})
```

### Event Logs

**Location**: `explorer_event_logs` repository ([Lines 123-125](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/pipeline.yaml#L123-L125))

**Contents**:
- Grammar evolution timeline
- Coverage improvements per iteration
- LLM API calls and costs
- Agent decision logs

### Web Visualization

**Tool**: `run_webview.py` ([README Lines 73-78](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/README.md#L73-L78))
- Live visualization of grammar evolution
- Coverage growth charts
- Agent exploration paths

## Key Algorithms

### Coverage Delta Computation

**Algorithm**:
1. Query coverage-guy for current coverage
2. Compare with baseline coverage
3. Identify uncovered functions/blocks
4. Rank by importance (call frequency, complexity)
5. Generate targeted grammars for top N

### Grammar Validation

**Process**:
1. Generate sample inputs from grammar
2. Feed to harness binary
3. Check for crashes or hangs
4. Validate grammar produces parseable inputs
5. Reject invalid grammars, log failures

### Budget Management

**LLM Cost Control**:
- $10 limit per task
- Track cumulative API costs
- Budget exception halts execution
- Event logging for cost analysis

## Performance Characteristics

### Generation Speed

- **Initial grammar**: Minutes to hours (LLM-dependent)
- **Refinement iteration**: 5-15 minutes per cycle
- **Delta mode**: 2-5x faster (fewer functions)

### Quality Metrics

- **Coverage improvement**: 20-50% over pure mutation
- **Bug discovery**: 2-5x faster for structured inputs
- **False positives**: Low (grammars produce valid inputs)

### Resource Usage

**Compute**:
- CPU: Variable (mostly LLM API calls)
- Memory: 2-4Gi
- Time: Hours (iterative refinement)

**Budget**:
- $10 per component per task
- Typical usage: $3-8 for full grammar generation

## Integration Points

**Sync Mechanism** ([Lines 524](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/grammar-guy/pipeline.yaml#L524)):
```bash
# Copy grammars to fuzzer sync directories
rsync -av {{ grammar_output }}/ /shared/fuzzer_sync/grammars/
```

**Fuzzer Pickup**:
- AFL++ automatically detects new grammars
- Jazzer reads from shared directory
- Grammars hot-reloaded during fuzzing

## Related Components

- **[Coverage-Guy](../coverage/coverage-guy.md)**: Provides feedback
- **[AFL++](../fuzzing/aflplusplus.md)**: Consumes grammars
- **[Jazzer](../fuzzing/jazzer.md)**: Java grammar support
- **[Grammaroomba](./grammaroomba.md)**: Grammar optimization
