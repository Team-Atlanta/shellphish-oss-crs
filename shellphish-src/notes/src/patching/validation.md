# Patch Validation

## Overview

Patch validation is the critical quality assurance stage that verifies generated patches meet correctness, functionality, and robustness requirements before submission. Both PatcherY and PatcherQ employ multi-stage validation pipelines that progressively test patches against increasingly strict criteria, from basic compilation to comprehensive fuzzing campaigns.

**Core Design Philosophy**: Validation operates as a fail-fast pipeline where patches must sequentially pass all enabled verification passes. Any failure immediately halts validation and provides detailed feedback to the patch generator for refinement.

**Shared Validation Objectives**:
1. **Correctness**: Patch must compile and eliminate the target vulnerability
2. **Functionality Preservation**: Patch must not break existing program behavior or tests
3. **Robustness**: Patch must withstand fuzzing and regression testing with related crashes
4. **Quality Assurance**: Patch must avoid naive or superficial fixes (PatcherQ only)

## Verification Pass Pipeline

The validation system implements a **sequential pipeline** where patches progress through multiple verification stages. The pipeline halts immediately upon the first failure, providing targeted feedback for patch refinement.

### PatcherQ Validation Pipeline

Configured in [`patch_verifier.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/patch_verifier.py#L22-L76):

**REGULAR Mode** (for crash-based POI reports):
```python
REGULAR_VERIFICATION_PASSES = [
    CompilerVerificationPass,      # Stage 1: Compilation
    BuildCheckVerificationPass,    # Stage 2: Harness integrity (optional)
    CrashVerificationPass,         # Stage 3: Crash elimination
    TestsVerificationPass,         # Stage 4: Functionality tests
    CriticPass,                    # Stage 5: LLM-based review (optional)
    RegressionVerificationPass,    # Stage 6: Related crash testing (optional)
    FuzzVerificationPass,          # Stage 7: Fuzzing campaign (optional)
]
```

**SARIF Mode** (for static analysis findings):
```python
SARIF_VERIFICATION_PASSES = [
    CompilerVerificationPass,
    BuildCheckVerificationPass,    # Optional
    TestsVerificationPass,
]
# CrashPass and FuzzPass omitted (no crashing input for static analysis)
```

**Pass Configurability** ([`config.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/config.py#L70-L85)):
- `use_build_check_pass: bool = True` - Enable harness verification
- `use_critic: bool = True` - Enable LLM-based patch review
- `use_reg_pass: bool = True` - Enable regression testing
- `use_fuzz_pass: bool = True` - Enable fuzzing validation
- `fuzz_patch_time: int = 450` - Fuzzing duration (7.5 minutes)

### PatcherY Validation Pipeline

Configured in [`patch_verifier.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/patch_verifier.py#L33-L43):

**Default Pipeline** (smart mode only):
```python
DEFAULT_PASSES = [
    (DuplicateVerificationPass, True),        # Stage 0: Duplicate detection
    (NewCodeCheckPass, True),                 # Stage 1: Non-empty patch check
    (CompileVerificationPass, True),          # Stage 2: Compilation
    (OssFuzzBuildCheckPass, True),           # Stage 3: OSS-Fuzz build check
    (AlertEliminationVerificationPass, True), # Stage 4: Alert elimination
    (RegressionPass, True),                   # Stage 5: Regression testing
    (FunctionalityVerificationPass, True),    # Stage 6: Functionality tests
    (SyzCallerVerificationPass, False),       # Stage 7: Syzkaller (disabled)
    (FuzzVerificationPass, True),            # Stage 8: Fuzzing campaign
]
```

**Key Difference**: PatcherY includes **DuplicateVerificationPass** and **NewCodeCheckPass** as pre-flight checks before compilation, and uses **AlertEliminationVerificationPass** instead of CrashPass.

## Verification Pass Details

### Stage 0: Duplicate Detection (PatcherY Only)

**Purpose**: Prevent wasting resources re-validating previously failed patches.

**Implementation**: [`DuplicateVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/duplicate_check_pass.py#L12-L26)

**Mechanism**:
- Maintains set of previously failed patches in `PatchVerifier.failed_patches`
- Compares current patch against failed set via Python object equality
- On duplicate detection, increases "failure heat" penalty by 0.1

**Failure Handling** ([line 22-24](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/duplicate_check_pass.py#L22-L24)):
```python
if self._patch in self._verifier.failed_patches:
    self._verifier.failure_heat += 0.1
    return False, "The Patch is a duplicate of a previously failed patch!"
```

**Rationale**: Avoids expensive recompilation and testing for patches that have already failed. The failure heat mechanism signals to the patcher that it may be stuck in a loop.

### Stage 1: Compilation Verification

**Purpose**: Ensure the patched code compiles successfully with the target sanitizer configuration.

**Implementation**:
- PatcherQ: [`CompilerVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/compile_pass.py#L15-L67)
- PatcherY: [`CompileVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/compile_pass.py#L48-L62)

**Workflow** (PatcherQ):

1. **Fresh Repository Creation** ([patch_verifier.py:78-100](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/patch_verifier.py#L78-L100)):
   - Creates temporary copy of project source and OSS-Fuzz configuration
   - Prevents pollution of original repository during validation
   - All subsequent passes operate on this fresh copy

2. **Patch Application and Build** ([compile_pass.py:34-39](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/compile_pass.py#L34-L39)):
   ```python
   build_result = self.cp.build_target(
       sanitizer=self.sanitizer_to_build_with,
       patch_content=self.git_diff,
       preserve_built_src_dir=True  # Keep artifacts for next passes
   )
   ```

3. **Build Result Capture**:
   - Stores `build_request_id` for tracking ([line 44](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/compile_pass.py#L44))
   - Captures stdout and stderr for error reporting

4. **Failure Handling** ([lines 46-64](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/compile_pass.py#L46-L64)):
   - Logs full compilation stderr and stdout
   - Writes error logs to temporary file for patch generator feedback
   - Raises `PatchedCodeDoesNotCompile` exception with log file path

**Output**: Built artifacts in `new_cp.project_path/artifacts/`, used by all subsequent verification passes.

### Stage 2: Build Check Verification

**Purpose**: Ensure the patch doesn't break fuzzer harness behavior, particularly that harnesses still generate code coverage.

**Implementation**:
- PatcherQ: [`BuildCheckVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/build_check_pass.py#L13-L79)
- PatcherY: [`OssFuzzBuildCheckPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/ossfuzz_build_check_pass.py)

**Why This Matters**: A patch that accidentally modifies harness entry points or removes critical code paths could cause the fuzzer to produce zero coverage, making the patch useless despite technically compiling.

**Workflow** (PatcherQ):

1. **Sanity Check** ([lines 39-45](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/build_check_pass.py#L39-L45)):
   ```python
   res = self.does_build_check_work(self.patcherq.build_configuration_id)
   if not res:
       logger.error("Build check does not work for current build. Skipping.")
       return True  # Pass by default if build check unavailable
   ```
   - Verifies the build check infrastructure is operational
   - Queries PDT agent for build check status

2. **Build Check Execution** ([lines 47-54](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/build_check_pass.py#L47-L54)):
   ```python
   test_result = self.cp.run_ossfuzz_build_check(
       sanitizer=self.patcherq.kwargs['sanitizer_to_build_with']
   )
   ```
   - Executes organizer-provided build check harness
   - Verifies coverage generation capability

3. **Failure Handling** ([lines 56-79](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/build_check_pass.py#L56-L79)):
   - Captures test stdout/stderr
   - Writes detailed logs to temporary file
   - Raises `PatchedCodeDoesNotPassBuildPass` exception

**Failure Modes**:
- Harness produces zero coverage (patch broke instrumentation)
- Harness crashes during initialization (patch introduced instability)
- Harness times out (patch introduced infinite loops)

### Stage 3: Crash Elimination Verification

**Purpose**: Verify the patch successfully eliminates the original vulnerability without introducing new crashes.

**Implementation**:
- PatcherQ: [`CrashVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/crash_pass.py#L19-L110)
- PatcherY: [`AlertEliminationVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/alert_elim_pass.py#L6-L47)

**Workflow** (PatcherQ):

1. **Multi-Input Testing** ([lines 61-68](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/crash_pass.py#L61-L68)):
   ```python
   for crashing_input_id, crashing_input in enumerate(crashing_inputs_to_test):
       res = self.cp.run_pov(
           self.harness_name,
           data_file=crashing_input.crashing_input_path,
           sanitizer=self.sanitizer_to_build_with,
           timeout=60*5  # 5 minute timeout per input
       )
   ```
   - Tests patch against all provided crashing inputs (not just the original)
   - Essential for ensuring comprehensive vulnerability elimination

2. **Exit Code Interpretation** ([lines 81-96](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/crash_pass.py#L81-L96)):
   - **Exit Code 124**: Timeout → Patch introduced hang → Raise `PatchedCodeHangs`
   - **Non-zero Exit Code**: Crash detected → Raise `PatchedCodeStillCrashes`
   - **Exit Code 0 + No Crash Report**: Success → Continue to next pass

3. **Partial Success Tracking** ([line 107](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/crash_pass.py#L107)):
   ```python
   patch_pass_this_number_of_crashing_input += 1
   ```
   - Counts how many inputs passed before failure
   - Included in exception metadata for feedback to patch generator

**Crash Report Parsing** ([lines 34-58](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/crash_pass.py#L34-L58)):
- Uses POI report metadata to identify target harness
- Optionally summarizes crash messages via LLM (GPT-4.1-mini)
- Extracts stack traces for root cause comparison

### Stage 4: Functionality Tests Verification

**Purpose**: Ensure the patch doesn't introduce regressions by breaking existing program functionality.

**Implementation**:
- PatcherQ: [`TestsVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/tests_pass.py#L14-L70)
- PatcherY: [`FunctionalityVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/func_verification_pass.py#L13-L35)

**Workflow** (PatcherQ):

1. **Patch Serialization** ([lines 28-32](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/tests_pass.py#L28-L32)):
   ```python
   git_diff_file_at = Path(tempfile.mktemp(prefix="patch."))
   with git_diff_file_at.open('w') as output_file:
       output_file.write(self.git_diff)
   ```
   - Writes git diff to temporary file for test harness consumption

2. **Test Execution** ([lines 35-40](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/tests_pass.py#L35-L40)):
   ```python
   test_result = self.cp.run_tests(
       patch_path=git_diff_file_at,
       sanitizer=self.all_args['sanitizer_to_build_with'],
       print_output=False
   )
   ```
   - Executes organizer-provided public tests
   - Tests may include unit tests, integration tests, or functional benchmarks

3. **Result Handling** ([lines 41-69](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/tests_pass.py#L41-L69)):
   - **No tests exist** (`tests_exist == False`): Assume pass, log warning
   - **All tests pass**: Continue to next stage
   - **Any test fails**: Capture stdout/stderr, raise `PatchedCodeDoesNotPassTests`

**Important Note**: Not all AIxCC challenges provide public tests. When unavailable, this pass effectively becomes a no-op but remains in the pipeline for consistency.

### Stage 5: Critic Pass (PatcherQ Only)

**Purpose**: Perform LLM-based review to identify naive, superficial, or easily bypassable patches that might pass automated tests but fail under adversarial scrutiny.

**Implementation**: [`CriticPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/critic_pass.py#L19-L65)

**Motivation** (from whitepaper):
> "This additional step was included based on the observation that in a few cases, the generated patches were easily circumvented (or too aggressive) despite careful prompt engineering of the agent."

**Workflow**:

1. **One-Time Activation** ([line 34](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/critic_pass.py#L34)):
   ```python
   Config.use_critic = False  # Disable for subsequent passes
   ```
   - Runs only once per patch attempt
   - Prevents infinite refinement loops from overly conservative critic

2. **CriticGuy Agent Invocation** ([lines 36-57](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/critic_pass.py#L36-L57)):
   ```python
   self.critic_guy = CriticGuy(
       project_name=self.patcherq.project_name,
       project_language=self.patcherq.project_language,
       root_cause_report=str(self.root_cause_report),
       patch=str(self.git_diff)
   )
   res = self.critic_guy.invoke().value
   ```
   - **Model**: GPT-4o-3 (different from patch generation models for independent perspective)
   - **No Tool Calling**: Operates purely on provided context without code exploration
   - **Single-Shot**: Produces one comprehensive review per invocation

3. **Fail-Forward Exception Handling** ([lines 46-58](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/critic_pass.py#L46-L58)):
   ```python
   except MaxToolCallsExceeded:
       return True  # Pass on max iterations
   except LLMApiBudgetExceededError:
       return True  # Pass on budget exhaustion
   except Exception as e:
       return True  # Pass on any unexpected error
   ```
   - **Rationale**: Prefer false positives (accepting bad patches) over false negatives (rejecting good patches)
   - Prevents critic failures from blocking potentially valid patches

4. **Verdict Processing** ([lines 59-64](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/critic_pass.py#L59-L64)):
   ```python
   if res['verdict'] == 'fail':
       raise PatchedCodeDoesNotPassCritic(res['feedback'])
   else:
       return True
   ```
   - **Verdict: pass** → Continue pipeline
   - **Verdict: fail** → Feedback integrated into next patch generation attempt

**Output Format** (from CriticGuy):
```xml
<feedback_report>
  <analysis>Detailed analysis of patch approach and potential issues</analysis>
  <verdict>pass or fail</verdict>
  <feedback>Specific actionable improvements if verdict is fail</feedback>
</feedback_report>
```

**Typical Rejection Reasons**:
- Patch only checks input values without fixing root cause (input validation bypass)
- Patch adds restrictive bounds that may break legitimate use cases (overfitting)
- Patch silences error without addressing underlying memory safety issue
- Patch is incomplete (e.g., fixes one code path but leaves other branches vulnerable)

### Stage 6: Regression Verification

**Purpose**: Test the patch against related crashing inputs from the same vulnerability bucket to ensure comprehensive mitigation.

**Implementation**:
- PatcherQ: [`RegressionVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/reg_pass.py#L17-L142)
- PatcherY: [`RegressionPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/regression_pass.py#L40-L171)

**Challenge**: Multiple fuzzing campaigns may discover different crashing inputs for the same underlying vulnerability. A patch that fixes the original crash but not related crashes is incomplete.

**Workflow** (PatcherQ):

1. **Crashing Input Retrieval** ([lines 41-50](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/reg_pass.py#L41-L50)):
   ```python
   def _get_crashing_inputs(self):
       crashing_input_nodes = Helper.get_crashing_inputs_from_bucket(
           self.bucket_id,
           20  # Test up to 20 related crashes
       )
   ```
   - Queries Analysis Graph for POVs in the same deduplication bucket
   - Bucket created by organizer based on crash signatures and root causes

2. **Relevance Filtering** ([lines 52-78](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/reg_pass.py#L52-L78)):
   ```python
   def _crash_in_relevant_location(self, pov) -> bool:
       stack_trace_functions = [extract from crash report]
       stack_trace_slice = stack_trace_functions[:3]

       # Check if crash in patched function
       if any(func in stack_trace_slice for func in self.functions_in_patch):
           return True

       # Check if crash in original crashing function
       if stack_trace_slice[0] == self.crashing_function:
           return True

       return False
   ```
   - **Why filtering?** Some bucket POVs may crash in unrelated code paths
   - Only fail validation if crash occurs in patched functions or original crash site

3. **POV Execution** ([lines 80-123](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/reg_pass.py#L80-L123)):
   ```python
   for crashing_input in crashing_inputs:
       crashed, exception = self.run_pov(crashing_input)
       if crashed:
           raise exception  # Fail immediately on first relevant crash
   ```
   - Tests each input with same harness and sanitizer as CrashPass
   - Distinguishes between new crashes and new hangs via exit codes

**PatcherY Regression Enhancement** ([regression_pass.py:101-114](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/regression_pass.py#L101-L114)):
```python
if self._verifier.regression_fuzzing_dir.exists():
    for crash_input in list(self._verifier.regression_fuzzing_dir.iterdir())[:5]:
        crashes, crash_info, stack_trace = self.run_pov(crash_input)
        if crashes and self._crash_in_relevant_location(stack_trace):
            return False, all_crash_info
```
- **Additional Test Source**: Previously discovered crashes from FuzzPass
- Creates regression suite that grows across patch iterations
- Prevents patch refinement from reintroducing previously fixed issues

### Stage 7: Fuzz Verification

**Purpose**: Conduct short fuzzing campaign to discover edge cases and bypasses that static analysis and targeted testing might miss.

**Implementation**:
- PatcherQ: [`FuzzVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/fuzz_pass.py#L34-L347)
- PatcherY: [`FuzzVerificationPass`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/fuzz_pass.py#L68-L417)

**Motivation**: Patches may pass all deterministic tests but still be bypassable with crafted inputs. Fuzzing provides probabilistic assurance against naive fixes.

**Workflow** (PatcherQ):

1. **Seed Corpus Creation** ([lines 80-104](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/fuzz_pass.py#L80-L104)):
   ```python
   corpus_zip = self._zip_seeds()
   inputs = [crash.crashing_input_path for crash in self.crashing_inputs_to_test]
   # Ensure at least 3 inputs (duplicate if needed)
   while len(inputs) < 3 and original_inputs:
       inputs.append(original_inputs[0])
   ```
   - Uses original crashing inputs as seed corpus
   - Ensures minimum diversity (3 inputs) by duplication if needed

2. **Language-Specific Fuzzer Setup**:

   **C/C++ Projects** ([lines 106-141](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/fuzz_pass.py#L106-L141)):
   ```python
   instrumentation = AFLPPInstrumentation()
   fuzz_envs = {
       'FUZZING_ENGINE': 'shellphish_aflpp',
       'ARTIPHISHELL_AFL_TIMEOUT': str(timeout),  # 450 seconds (7.5 min)
       'FORCED_DO_CMPLOG': '1',
       'FORCED_USE_CUSTOM_MUTATOR': '1',
   }
   ```
   - **Fuzzer**: AFL++ with custom shellphish instrumentation
   - **Timeout**: Configurable via `Config.fuzz_patch_time` (default 450s)
   - **CMPLOG**: Enables comparison logging for better input generation
   - **Custom Mutator**: Shellphish-specific mutation strategies

   **Java Projects** ([lines 143-172](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/fuzz_pass.py#L143-L172)):
   ```python
   instrumentation = JazzerInstrumentation()
   fuzz_envs = {
       'ARTIPHISHELL_JAZZER_BENIGN_SEEDS': str(corpus_dir),
       'ARTIPHISHELL_JAZZER_CRASHING_SEEDS': str(sync_dir / instance_name / "crashes")
   }
   ```
   - **Fuzzer**: Jazzer (JVM-native coverage-guided fuzzer)
   - **Longer Timeout**: 10 minutes for Java (slower startup/instrumentation)

3. **Instrumented Build** ([lines 134-138](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/fuzz_pass.py#L134-L138)):
   ```python
   instr_project = InstrumentedOssFuzzProject(
       instrumentation,
       oss_fuzz_project_path=self.new_oss_fuzz_dir,
       project_source=self.new_source_dir
   )
   build_res = instr_project.build_target(
       sanitizer=self.poi_report.sanitizer,
       patch_content=self.git_diff
   )
   ```
   - Rebuilds project with fuzzing instrumentation (separate from validation build)
   - Applies same patch to ensure consistency

4. **Fuzzing Execution** ([lines 186-219](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/fuzz_pass.py#L186-L219)):
   ```python
   with FUZZING_LOCK:  # Serialize fuzzing to prevent resource contention
       self._fuzz_core(instance_name, sync_dir, timeout=timeout)
   ```
   - **Resource Management**: Global lock prevents parallel fuzzing instances from starving each other
   - **Timeout Enforcement**: Hard timeout via `concurrent.futures.ThreadPoolExecutor` (lines 335-342)

5. **Crash Discovery and Reproduction** ([lines 222-254](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/fuzz_pass.py#L222-L254)):
   ```python
   crash_dir_path = sync_dir / instance_name / 'crashes'
   crash_inputs = list(crash_dir_path.iterdir())

   for crash_file in crash_inputs:
       if crash_file.suffix == '.txt':
           continue  # Skip fuzzer metadata files

       is_crashing, exception = self.run_pov(crash_file)
       if is_crashing:
           relevant_crashes.append(crash_file)
   ```
   - **Why reproduce?** Fuzzers may report "crashes" that are false positives (e.g., timeout artifacts)
   - Only true crashes that reproduce under clean execution count as failures

6. **Relevance Filtering** ([lines 301-327](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/fuzz_pass.py#L301-L327)):
   ```python
   def _crash_in_relevant_location(self, pov) -> bool:
       stack_trace_slice = stack_trace_functions[:3]

       if any(func in stack_trace_slice for func in self.functions_in_patch):
           return True

       if stack_trace_slice[0] == self.crashing_function:
           return True

       return False
   ```
   - Same relevance logic as RegressionPass
   - Ignores crashes in unrelated code (likely pre-existing bugs)

7. **Crash Persistence** ([lines 174-184](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/fuzz_pass.py#L174-L184)):
   ```python
   if self.SAVE_CRASHES:
       self._save_crash_inputs(relevant_crashes)
   ```
   - Saves discovered crashes to `crashing_inputs_to_test` list
   - Enables regression testing in future patch iterations (feeds RegressionPass)

**Timeout Strategy** (PatcherQ):
```python
TIMEOUT = 60 * 7.5  # 7.5 minutes outer timeout
TOTAL_FUZZING_TIME = 450  # 7.5 minutes fuzzing campaign

with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
    future = executor.submit(self._fuzz_for_crashes)
    try:
        passed, exception = future.result(timeout=TIMEOUT)
    except concurrent.futures.TimeoutError:
        return True  # Pass on timeout (fuzzing inconclusive)
```
- **Double Timeout**: Inner timeout (fuzzing campaign) + outer timeout (safety net)
- **Fail-Forward**: Timeouts are treated as passes (fuzzing is best-effort verification)

**PatcherY Enhancements**:

1. **Smart Mode Only** ([fuzz_pass.py:414-417](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/fuzz_pass.py#L414-L417)):
   ```python
   if not self.smart_mode:
       return True, "Fuzz pass only applicable to smart modes."
   ```
   - Fuzzing disabled in basic mode to reduce validation overhead

2. **AIJON Instrumentation Support** ([fuzz_pass.py:181-201](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/fuzz_pass.py#L181-L201)):
   ```python
   if use_aijon and AIJON_AVAILABLE:
       instrumentation = AIJONInstrumentation()
       patch_path = annotate_from_patch(patch_path, ...)
       if "IJON" not in patch_data:
           raise RuntimeError("AIJON annotations not found")
   ```
   - AIJON: Annotation-based fuzzing that targets specific code regions
   - Fallback to AFL++ if AIJON annotation fails

3. **Regression Directory Integration**:
   - Discovered crashes saved to `self._verifier.regression_fuzzing_dir`
   - RegressionPass tests new patches against this growing corpus
   - Creates cumulative robustness testing across patch iterations

## PatcherQ vs PatcherY Validation Differences

| Aspect | PatcherQ | PatcherY |
|--------|----------|----------|
| **Pipeline Stages** | 7 passes (compile → build → crash → tests → critic → regression → fuzz) | 9 passes (duplicate → empty → compile → build → alert → regression → tests → syzkaller → fuzz) |
| **Pre-flight Checks** | None | DuplicatePass, NewCodeCheckPass |
| **Crash Verification** | CrashVerificationPass (multi-input) | AlertEliminationVerificationPass (sanitizer-agnostic) |
| **LLM Review** | CriticPass (GPT-4o-3, one-shot) | None |
| **Fuzzing** | 7.5 min (C/C++), 10 min (Java) | 5 min (configurable) |
| **Regression Testing** | Bucket-based POV retrieval | Bucket + fuzzing corpus |
| **Configuration** | Highly configurable (5 optional passes) | Fixed pipeline with should_skip logic |
| **Failure Handling** | Immediate halt | Immediate halt (with failure_heat tracking) |
| **Fresh Repository** | Created once per patch | Inherited from Kumushi program abstraction |

**Key Philosophical Difference**:

- **PatcherQ**: Assumes LLM-generated patches may be sophisticated but occasionally naive → Uses CriticPass as safety net
- **PatcherY**: Operates within constrained LLM framework → Relies on DuplicatePass to detect iteration loops

## Configuration and Tuning

### PatcherQ Configuration

**Location**: [`config.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/config.py)

**Validation Toggle Flags**:
```python
use_build_check_pass: bool = True      # Default enabled
use_critic: bool = True                # Default enabled
use_reg_pass: bool = True              # Default enabled
use_fuzz_pass: bool = True             # Default enabled
```

**Fuzzing Parameters**:
```python
fuzz_patch_time: int = 450  # seconds (7.5 minutes)
```

**Build Configuration**:
```python
suppress_build_output: bool = False    # Show compilation logs
resolve_compile_generated_files: bool = True  # Handle generated headers
```

**Operational Modes**:
```python
class PatcherqMode(Enum):
    PATCH = 'patch'   # Full validation pipeline
    SARIF = 'sarif'   # Skips CrashPass and FuzzPass
    REFINE = 'refine' # Same as PATCH
```

### PatcherY Configuration

**Location**: [`patch_verifier.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/patch_verifier.py)

**Pipeline Customization**:
```python
def __init__(self, prog_info, passes=None, smart_mode=False):
    self._passes = passes or self.DEFAULT_PASSES
    self.smart_mode = smart_mode
```
- Custom pass list can be provided at instantiation
- Smart mode enables fuzzing and regression testing

**Fuzzing Parameters** ([fuzz_pass.py:71-74](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/fuzz_pass.py#L71-L74)):
```python
TIMEOUT = 60*15            # 15 min outer timeout
TOTAL_FUZZING_TIME = 60*5  # 5 min fuzzing campaign
THREAD_FUZZING = False     # Disable threaded fuzzing
USE_AIJON = False          # Disable AIJON by default
SAVE_CRASHES = True        # Enable crash persistence
```

**Timeout Configuration**:
```python
class BaseVerificationPass:
    TIMEOUT = 10 * 60  # Default 10 minutes per pass
    FAIL_ON_EXCEPTION = False  # Fail-forward on unexpected errors
```

## Integration with Patching Workflow

### Input Requirements

**PatcherQ** ([patch_verifier.py:38-47](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/patch_verifier.py#L38-L47)):
```python
def __init__(self, cp, patch, git_diff, functions_in_patch, language,
             root_cause_report, patcherq, all_args):
    self.cp = cp                              # OSSFuzzProject instance
    self.patch = patch                        # Structured patch dict
    self.git_diff = git_diff                  # Raw git diff string
    self.functions_in_patch = functions_in_patch  # List of modified functions
    self.language = language                  # "c", "cpp", "java"
    self.root_cause_report = root_cause_report    # TriageGuy analysis
    self.all_args = all_args                  # Metadata bundle
```

**Required Metadata** (from `all_args`):
- `project_yaml`: Augmented project metadata (harness names, sanitizers)
- `crashing_input_path`: Original POV that triggered vulnerability
- `poi_report`: POI Guy analysis (stack trace, crash type)
- `sanitizer_to_build_with`: Target sanitizer (e.g., "address", "undefined")
- `bucket_id`: Deduplication bucket for regression testing
- `functions_by_file_index`: Code structure mapping

### Validation Invocation

**PatcherQ** ([programmer.py:437-784](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/utils/programmer.py#L437-L784)):
```python
try:
    verifier = PatchVerifier(
        cp=self.cp, patch=patch_dict, git_diff=git_diff,
        functions_in_patch=functions_in_patch, ...
    )
    validated_cp = verifier.run()  # Returns patched OSSFuzzProject if success
except PatchedCodeDoesNotCompile as e:
    feedback = generate_compile_feedback(e)
    return self.generate(feedback=feedback)  # Retry with feedback
except PatchedCodeStillCrashes as e:
    feedback = generate_crash_feedback(e)
    return self.generate(feedback=feedback)
# ... similar handling for other exceptions
```

**Feedback Loop**:
1. PatchVerifier raises exception with detailed error context
2. Programmer generates natural language feedback from exception
3. Feedback injected into ProgrammerGuy's next invocation
4. Process repeats until success or attempt limit reached

### Output Artifacts

**Successful Validation**:
- **Patched Project**: `validated_cp` (OSSFuzzProject with built artifacts)
- **Build Request ID**: Stored for tracking and debugging
- **Verification Metadata**: Captured in patch metadata YAML

**Failed Validation**:
- **Exception Type**: Indicates which pass failed (e.g., `PatchedCodeDoesNotPassTests`)
- **Error Logs**: Temporary files with detailed stdout/stderr
- **Feedback Context**: Natural language explanation for patch generator

### Pipeline Integration

**Upstream** (Patch Generation):
- PatcherQ: Programmer feedback loop ([programmer.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/utils/programmer.py))
- PatcherY: Kumushi patcher iteration ([patcher.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/patcher.py))

**Downstream** (Submission):
- Validated patches uploaded to Analysis Graph as `GeneratedPatch` nodes
- Relationships created: `MITIGATED_POV_REPORT`, `NON_MITIGATED_POV_REPORT`
- PatcherG consumes validated patches for deduplication and submission

**Lateral** (Refinement):
- Fuzzing crashes feed back into RegressionPass for iterative robustness
- CriticPass feedback influences next ProgrammerGuy invocation
- Duplicate detection prevents re-validation of known failures

## Performance Characteristics

### Time Complexity

**Per-Pass Breakdown** (typical 12-hour full mode challenge):

| Pass | PatcherQ | PatcherY | Typical Duration |
|------|----------|----------|------------------|
| CompilerPass | ~2-5 min | ~2-5 min | Project size dependent |
| BuildCheckPass | ~30-60 sec | ~30-60 sec | Harness complexity dependent |
| CrashPass | ~30 sec per input | ~30 sec per input | Input count × 5 min timeout |
| TestsPass | ~0-10 min | ~0-10 min | Test suite dependent |
| CriticPass | ~1-2 min | N/A | Single LLM call |
| RegressionPass | ~5-10 min | ~5-10 min | 20 POVs × 5 min timeout |
| FuzzPass | 7.5 min | 5 min | Configured timeout |

**Total Validation Time**: 15-35 minutes per patch attempt (dominated by fuzzing and regression)

**Optimization Opportunities**:
- Parallel POV execution in CrashPass and RegressionPass (currently sequential)
- Adaptive fuzzing timeout based on project complexity
- Early termination in RegressionPass after N consecutive passes

### Resource Utilization

**CPU**:
- Compilation: 100% utilization (multi-core builds)
- Fuzzing: 100% utilization (CPU-bound)
- Other passes: 20-50% utilization (I/O bound)

**Memory**:
- Fresh repository copy: ~100-500MB per validation
- Fuzzing: ~500MB-2GB (AFL++ map size + seed corpus)
- Peak: ~3-4GB for large Java projects with Jazzer

**Disk**:
- Temporary directories: ~1-5GB per validation attempt
- Crash corpus: ~10-100MB (grows over time)
- Build artifacts: ~500MB-2GB

**Network**:
- Build check API calls: ~1-2 requests per validation
- Metadata uploads: ~10-50KB per validated patch

## Exception Hierarchy

**PatcherQ** ([`errors.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/exceptions/errors.py)):

```python
class PatchedCodeDoesNotCompile(Exception)
class PatchedCodeDoesNotPassBuildPass(Exception)
class PatchedCodeStillCrashes(Exception)
class PatchedCodeHangs(Exception)
class PatchedCodeDoesNotPassTests(Exception)
class PatchedCodeDoesNotPassCritic(Exception)
```

**Exception Metadata**:
- `num_passed`: Count of inputs that passed before failure (CrashPass, RegressionPass)
- `new_crash`: Flag indicating new crash vs. original crash persistence
- `new_hang`: Flag indicating patch introduced timeout

## Key Implementation Files

**PatcherQ**:
- [`patch_verifier.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/patch_verifier.py) - Pipeline orchestration
- [`verification_passes/__init__.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/__init__.py) - Pass registry
- [`verification_passes/base_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/base_pass.py) - Base class
- [`verification_passes/compile_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/compile_pass.py) - Compilation verification
- [`verification_passes/crash_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/crash_pass.py) - Crash elimination
- [`verification_passes/critic_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/critic_pass.py) - LLM-based review
- [`verification_passes/fuzz_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/fuzz_pass.py) - Fuzzing validation
- [`verification_passes/reg_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/verification_passes/reg_pass.py) - Regression testing
- [`exceptions/errors.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/src/patcherq/patch_verifier/exceptions/errors.py) - Exception definitions

**PatcherY**:
- [`patch_verifier.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/patch_verifier.py) - Pipeline orchestration
- [`verification_passes/base_verification_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/base_verification_pass.py) - Base class with timeout
- [`verification_passes/compile_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/compile_pass.py) - Compilation verification
- [`verification_passes/alert_elim_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/alert_elim_pass.py) - Alert elimination
- [`verification_passes/duplicate_check_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/duplicate_check_pass.py) - Duplicate detection
- [`verification_passes/fuzz_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/fuzz_pass.py) - Fuzzing with AIJON support
- [`verification_passes/regression_pass.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patchery/patchery/verifier/verification_passes/regression_pass.py) - Regression with fuzzing corpus

**Shared Infrastructure**:
- [`shellphish_crs_utils/oss_fuzz/project.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/project.py) - Build and test execution
- [`kumushi/data/program.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/kumu-shi/kumushi/data/program.py) - Program abstraction for PatcherY
