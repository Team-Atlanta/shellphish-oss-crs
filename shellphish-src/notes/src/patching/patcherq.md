# PatcherQ

## Overview

PatcherQ is an LLM-driven automated program repair (APR) system designed as an orthogonal complement to [PatcherY](patchery.md). While PatcherY operates with constrained LLM freedom using pre-defined function clusters from Kumushi, PatcherQ grants maximum LLM autonomy to reason about vulnerabilities, root causes, and patches without adhering to rigid schemes like "patch one function at a time."

The system operates through a two-agent architecture: a **root-cause agent** that analyzes vulnerabilities to produce natural language reports identifying problematic code and required modifications, and a **programmer agent** that transforms these reports into concrete patches. This design enables PatcherQ to handle complex vulnerabilities requiring multi-function or multi-file changes that might challenge more constrained approaches.

PatcherQ supports three operational modes: **PATCH mode** for new vulnerabilities from POI reports, **SARIF mode** for patching static analysis findings, and **REFINE mode** for improving previously failed patches with new crashing inputs.

## Architecture

### Operating Modes

PatcherQ supports three distinct modes defined in [`config.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/config.py#L14-L19):

1. **PATCH Mode**: Patches new vulnerabilities discovered from POI (Points of Interest) crash reports, using DyVA or TriageGuy for root-cause analysis
2. **SARIF Mode**: Processes SARIF-format static analysis reports to validate and patch identified vulnerabilities
3. **REFINE Mode**: Refines previously failed patches when new crashing inputs are discovered, attempting to create more comprehensive fixes

### Main Control Flow

The core workflow is orchestrated in [`main.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/main.py) with two nested loops:

**Outer Budget Recovery Loop** (Lines 90-194): Handles LLM budget exhaustion by implementing "nap mode" - when all configured LLMs exhaust their budgets, PatcherQ sleeps until the next budget renewal period (configurable via `nap_duration`, default 7 minutes) before retrying, up to a maximum number of naps (`nap_becomes_death_after`, default 20).

**Inner Root-Cause Report Loop** (Lines 97-147): Iterates through available root-cause reports generated from different sources (DyVA, multiple TriageGuy LLMs). For each report, it instantiates a Programmer that executes a feedback loop attempting patch generation and verification.

The system implements **greedy patching** (configurable via `Config.greedy_patching`): when enabled, it stops after the first successfully verified patch; when disabled, it continues exploring all root-cause reports to potentially find multiple solutions.

### Two-Agent Architecture

#### Root-Cause Agent (TriageGuy)

Implemented in [`triageGuy.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/triageGuy.py), this agent analyzes crash reports to produce structured root-cause analyses. It operates with:

- **Input**: Initial context report containing crash details, stack traces, and vulnerability information
- **Tools**: Code exploration utilities (`show_file_at`, `get_functions_by_file`, `search_string_in_file`), optional CodeQL and language server integration
- **Output**: Structured report in XML format containing:

  ```xml
  <root_cause_report>
    <description>Natural language explanation of the bug</description>
    <change>
      <file>path/to/file.c</file>
      <fix>Description of required modification</fix>
      <fix>Additional modification if needed</fix>
    </change>
    ...
  </root_cause_report>
  ```

The agent can be configured with multiple LLM backends (default: `claude-3.7-sonnet`, `claude-4-opus`) specified in [`config.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/config.py#L64). Each LLM produces an independent root-cause report, providing diversity in analysis approaches.

#### Programmer Agent (ProgrammerGuy)

Implemented in [`programmerGuy.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/programmerGuy.py), this agent transforms root-cause reports into executable patches through an iterative feedback loop. Key features:

- **Input**: Root-cause report, project language, optional sanitizer hints, delta mode diff hints
- **Tools**: Same code exploration toolkit as TriageGuy, with tool selection dynamically adapted based on failure mode (e.g., log analysis tools enabled for compilation failures)
- **Output**: Structured patch in AutoCodeRover format:

  ```xml
  <patch_report>
    <change>
      <file>path/to/file.c</file>
      <line><start>10</start><end>15</end></line>
      <original>original code block</original>
      <patched>modified code block</patched>
    </change>
    ...
  </patch_report>
  ```

The agent employs **brain surgery mode** (configurable, default enabled): instead of creating fresh agent instances when switching LLMs, it performs runtime model swapping to preserve conversation history, improving context continuity.

### Root-Cause Generation Strategy

The [`RootCauseGenerator`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/utils/root_cause_generator.py) manages root-cause report production from multiple sources:

**Source Priority**:

1. **DyVA Report** (if available in PATCH mode): Pre-computed dynamic analysis report from the DyVA component, used as the first root-cause attempt
2. **SARIF Report** (in SARIF mode): Static analysis findings parsed from SARIF format files
3. **TriageGuy LLMs**: Multiple LLM models analyze the crash independently, each producing a distinct root-cause perspective

The generator tracks which reports have been successfully produced versus those still pending (e.g., due to budget exhaustion), enabling the budget recovery mechanism to resume from the correct state after napping.

## Patch Generation and Verification

### Programmer Feedback Loop

The [`Programmer`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/utils/programmer.py) class implements a sophisticated feedback loop with two primary methods:

**`generate()`** (Lines 176-436): Invokes ProgrammerGuy to produce a patch, handling various failure modes:

- **Budget/Rate Limit Handling**: Automatically switches to the next configured LLM model, implements napping if all models exhausted
- **Patch Validation**: Checks for illegal patch locations (e.g., fuzzer harnesses), incorrect file paths, corrupted patches
- **Duplicate Detection**: Uses SHA-256 hashing to identify previously attempted patches, replays cached verification results to save time
- **Attempt Limits**: Tracks total attempts (`max_programmer_total_attempts: 11`) and per-failure-type limits (compile: 4, crash: 4, tests: 2)

**`verify()`** (Lines 437-784): Runs verification passes on generated patches, providing detailed feedback for each failure:

- **Compilation Failures**: Provides stderr log paths, guides agent to scroll to end for actual errors
- **Crash Failures**: Distinguishes between original crash persistence and new crashes introduced by the patch, includes full crash reports
- **Test Failures**: Indicates functionality breakage, provides test output logs
- **Critic Failures**: Incorporates LLM-based review feedback for patch refinement

Each failure updates the patch state (`no-compile`, `still-crash`, `no-tests`, `no-critic`) and increments corresponding attempt counters, enabling targeted retry limits.

### Patch Cache

Implemented in [`patch_cache.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_generator/patch_cache/patch_cache.py), this component:

- **Deduplicates Patches**: Uses SHA-256 hashing of patch content to identify duplicates
- **Caches Verification Results**: Stores verification outcomes (compile success, crash results, etc.) to avoid redundant expensive operations
- **Replay Actions**: For duplicate patches, directly applies previously cached feedback to the agent without re-running verification

This optimization is critical given that LLMs may regenerate similar patches, especially when operating with temperature > 0 or when multiple root-cause reports lead to similar conclusions.

### Verification Pass Pipeline

The [`PatchVerifier`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/patch_verifier.py) orchestrates multiple verification passes in sequence:

1. **CompilerPass**: Validates the patched code compiles successfully
2. **BuildCheckPass**: Ensures patch doesn't break harness behavior or introduce zero coverage (configurable, default enabled)
3. **CrashPass**: Confirms the original crashing input no longer triggers the vulnerability
4. **TestsPass**: Runs project functionality tests to detect unintended side effects
5. **CriticPass**: LLM-based review for naive patches or bypass opportunities (configurable, default enabled)
6. **RegressionPass**: Tests against similar crashing inputs from the same bucket (configurable, default enabled)
7. **FuzzPass**: Short fuzzing session (default 7.5 minutes) to detect incomplete fixes (configurable, default enabled)

The pipeline is configurable via [`config.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/config.py#L70-L85), allowing teams to adjust verification rigor based on competition phases or resource constraints.

## CriticPass: LLM-Based Patch Review

The [CriticPass](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/critic_pass.py) represents a unique verification approach that addresses a critical observation: despite careful prompt engineering, ProgrammerGuy occasionally generates naive patches that are easily circumvented or overly aggressive.

### Design

Implemented via [CriticGuy](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/criticGuy.py) agent:

- **Model**: Uses GPT-4o-3 (different from patch generation models to provide independent perspective)
- **No Tool Calling**: Operates without code exploration tools, relying solely on the provided patch and root-cause report
- **Single-Shot Analysis**: Produces one comprehensive review per patch

**Input Context**:

- Project name and language
- Root-cause report that motivated the patch
- Generated patch diff

**Output Format**:

```xml
<feedback_report>
  <analysis>Detailed analysis of patch approach and potential issues</analysis>
  <verdict>pass or fail</verdict>
  <feedback>Specific actionable improvements if verdict is fail</feedback>
</feedback_report>
```

### One-Time Refinement Protocol

CriticPass implements a carefully balanced protocol:

1. **Single Activation**: Runs only once per patch attempt (set `Config.use_critic = False` after first run at [line 34](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/critic_pass.py#L34))
2. **Fail-Forward on Errors**: If CriticGuy encounters budget exhaustion, max iterations, or exceptions, returns `True` (pass) rather than blocking potentially valid patches
3. **Feedback Integration**: On `verdict: fail`, raises `PatchedCodeDoesNotPassCritic` exception containing feedback, which Programmer incorporates into the next patch attempt

This design mitigates the risk of LLM hallucination or over-conservatism in verification: a critic that incorrectly rejects valid patches gets only one opportunity to intervene, preventing infinite rejection loops.

### Rationale

The whitepaper notes: "This additional step was included based on the observation that in a few cases, the generated patches were easily circumvented (or too aggressive) despite careful prompt engineering of the agent." The CriticPass thus serves as a safety net for edge cases where prompt engineering alone proves insufficient, without imposing excessive computational overhead or false rejection risk.

## Configuration and Tuning

Key configuration parameters in [`config.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/config.py):

### Budget Management

- `nap_mode: bool = True`: Enable budget recovery via sleeping
- `nap_duration: int = 7`: Minutes until next budget tick
- `nap_becomes_death_after: int = 20`: Maximum naps before giving up

### LLM Selection

- `triage_llms: list = ['claude-3.7-sonnet', 'claude-4-opus']`: Models for root-cause analysis
- `programmer_llms: list = ['claude-3.7-sonnet']`: Models for patch generation
- `issue_llms: list = ['claude-3.7-sonnet', 'gpt-4.1']`: Models for POI report parsing

### Attempt Limits

- `max_programmer_total_attempts: int = 11`: Total feedback loop iterations
- `max_programmer_attempts_compile: int = 4`: Consecutive compilation failures
- `max_programmer_attempts_crash: int = 4`: Consecutive crash failures
- `max_programmer_attempts_tests: int = 2`: Consecutive test failures
- `max_programmer_duplicate_patches: int = 3`: Duplicate patch tolerance

### Verification Passes

- `use_critic: bool = True`: Enable CriticPass
- `use_fuzz_pass: bool = True`: Enable FuzzPass
- `use_reg_pass: bool = True`: Enable RegressionPass
- `fuzz_patch_time: int = 450`: Fuzzing duration in seconds (7.5 minutes)

### Strategy Options

- `greedy_patching: bool = True`: Stop after first successful patch
- `use_dyva_report: bool = True`: Prioritize DyVA root-cause reports
- `programmer_brain_surgery: bool = True`: Preserve conversation history when switching LLMs

## Integration with Pipeline

PatcherQ integrates into the broader CRS pipeline through several mechanisms:

### Input Dependencies

**PATCH Mode** ([`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/pipeline.yaml)):

- POI crash reports from POVGuy
- Optional DyVA root-cause analysis reports
- Project source code and OSS-Fuzz configuration
- Build artifacts from BobTheBuilder

**SARIF Mode**:

- SARIF-format static analysis reports
- Function resolver index for mapping SARIF locations

**REFINE Mode**:

- Previously failed patch ID
- New crashing input that bypassed the failed patch
- Bucket ID linking related crashes

### Output Artifacts

**Primary Outputs**:

- **Patch File**: Git diff format patch
- **Patch Metadata**: YAML file containing patcher name, cost, POI report ID, build request ID
- **Analysis Graph Upload**: Patches uploaded to Neo4j database with relationships to POI reports

**Optional Outputs** (configurable):

- **SARIF Reports**: Generated vulnerability descriptions (`generate_sarif: bool`)
- **Bypass Requests**: Metadata for DiscoveryGuy to attempt bypass (`emit_bypass_request: bool`)
- **Patched Artifacts**: Built binaries with patch applied (`emit_patched_artifacts: bool`)

### Downstream Consumers

1. **PatcherG**: Deduplicates patches and manages submission strategy
2. **Patch Patrol**: Validates patches against competition rules
3. **DiscoveryGuy**: Attempts to bypass submitted patches (if bypass requests enabled)
4. **PatcherQ Refine**: Consumes failed patches to generate improved versions

## Delta Mode Support

PatcherQ includes specialized support for delta mode challenges through [`peek_diff.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/toolbox/peek_diff.py):

**Delta Hints Generation** ([`programmerGuy.py` lines 262-272](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/programmerGuy.py#L262-L272)):

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

These hints are injected into ProgrammerGuy's prompt, focusing patch generation on modified functions and providing git diff context to understand what changed.

## Comparison with PatcherY

| Aspect | PatcherY | PatcherQ |
|--------|----------|----------|
| **LLM Freedom** | Constrained to pre-defined function clusters | Maximum freedom to explore and reason |
| **Root-Cause Analysis** | External (Kumushi) | Integrated LLM agents (TriageGuy/DyVA) |
| **Patching Strategy** | One function cluster at a time | Arbitrary multi-function/multi-file changes |
| **Verification** | CompilerPass → BuildCheckPass → CrashPass → TestsPass → RegressionPass → FuzzPass | Same + **CriticPass** (LLM-based review) |
| **Iteration Approach** | Simple retry with feedback (max 10 attempts) | Complex feedback loop with failure-specific limits and patch caching |
| **Use Case** | Fast patching of localized bugs | Complex vulnerabilities requiring broader reasoning |

The whitepaper states: "The key difference lies in their fundamental approaches to APR: while PatcherY performs patching through a one-shot request with limited LLM-freedom, PatcherQ takes the opposite stance by granting the LLM maximum freedom."

## Performance Characteristics

### Time Complexity

Based on configuration defaults:

**Per Root-Cause Report**:

- TriageGuy invocation: ~75 tool iterations max
- ProgrammerGuy attempts: Up to 11 total attempts × 70 tool iterations each
- Verification per attempt:
  - Compilation: ~2-5 minutes
  - CrashPass: ~30 seconds per crashing input
  - TestsPass: Project-dependent (0-10 minutes)
  - CriticPass: ~1-2 minutes (single LLM call)
  - FuzzPass: 7.5 minutes (configurable)

**Total per Vulnerability**: 20-60 minutes depending on:

- Number of triage LLMs configured (default: 2)
- Feedback loop iterations needed
- Whether DyVA report is available (saves one TriageGuy invocation)
- Greedy patching setting (stops early vs explores all reports)

### Cost Characteristics

Tracked via `agentlib.lib.agents.agent.global_event_dumper.total_cost_per_million` and stored in patch metadata:

**Typical Costs** (2024 pricing):

- TriageGuy (Claude 3.7 Sonnet): $0.50-2.00 per invocation
- ProgrammerGuy (Claude 3.7 Sonnet): $1.00-5.00 per successful patch
- CriticGuy (GPT-4o-3): $0.20-0.50 per review
- **Total per Patch**: $2-15 depending on iteration count

Budget management via nap mode enables cost control while maintaining progress.

## Limitations and Edge Cases

1. **Max Tool Calls**: Both TriageGuy and ProgrammerGuy have max iteration limits (75 and 70 respectively), causing hard failures if complex codebases require excessive exploration

2. **Patch Format Recovery**: Complex patches may require multiple LLM calls to fix formatting errors (max 3 attempts), occasionally failing on deeply nested structures

3. **Duplicate Patch Cycling**: If ProgrammerGuy repeatedly generates the same incorrect patch, the system may exhaust attempts without progress despite feedback

4. **CriticPass False Negatives**: A single incorrect rejection from CriticGuy can waste an otherwise valid patch, though this is mitigated by the one-time activation limit

5. **Delta Mode Scope**: Relies on accurate function identification from diffs; complex refactorings may confuse the delta hint generation

6. **SARIF Parsing**: Assumes well-formed SARIF files; malformed reports cause early exit without fallback strategies

## Key Implementation Files

- [`main.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/main.py): Core orchestration with budget recovery and root-cause loops
- [`config.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/config.py): All tuning parameters and operating modes
- [`agents/triageGuy.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/triageGuy.py): Root-cause analysis agent
- [`agents/programmerGuy.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/programmerGuy.py): Patch generation agent
- [`agents/criticGuy.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/agents/criticGuy.py): LLM-based patch review agent
- [`utils/programmer.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/utils/programmer.py): Feedback loop orchestration
- [`utils/root_cause_generator.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/utils/root_cause_generator.py): Multi-source root-cause report management
- [`patch_verifier/patch_verifier.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/patch_verifier.py): Verification pass pipeline
- [`patch_verifier/verification_passes/critic_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/critic_pass.py): CriticPass implementation
- [`patch_generator/patch_cache/patch_cache.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_generator/patch_cache/patch_cache.py): Duplicate patch detection and caching
