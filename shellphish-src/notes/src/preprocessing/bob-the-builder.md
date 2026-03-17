# Bob the Builder

## Summary

Bob the Builder creates multiple instrumented builds of the target application for different analysis and fuzzing purposes. It produces canonical, debug, and coverage builds using the OSS-Fuzz infrastructure with various sanitizers and instrumentations. All builds execute via the task service in containerized environments with priority scheduling and resource quotas.

> From whitepaper [Section 4.1](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/notes/src/whitepaper/Artiphishell-3.md#41-bob-the-builder):
>
> The first step after receiving the task is performed by the Bob the Builder agent. Bob the Builder creates various artifacts, depending on the language of the target application.

## Build Types

### 1. Canonical Build

**Purpose:** Standard libFuzzer-instrumented build for general fuzzing.

**Implementation:** [pipelines/preprocessing.yaml:505-593](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L505-L593)

**Configuration:**

- **Instrumentation:** libFuzzer
- **Sanitizer:** First from project metadata (typically AddressSanitizer)
- **Architecture:** x86_64
- **Priority:** 20B (highest among preprocessing tasks)
- **Timeout:** 180 minutes
- **Resources:** 6 CPU, 26Gi RAM (initial), scalable to 10 CPU, 40Gi RAM

**Process:**

1. Build Docker images for builder and runner environments
2. Execute `oss-fuzz-build` with libFuzzer instrumentation
3. Preserve built source directory (`--preserve-built-src-dir`)
4. Store artifacts in `canonical_build_artifacts` repository
5. Record builder and runner image names for reproducibility

**Key Features:**

- Uses task service for distributed building (`--use-task-service`)
- Automatically handles source code retrieval
- Creates harness binaries in `out/` directory
- Generates `shellphish_build_metadata.yaml` with harness list

### 2. Debug Build (Multi-Sanitizer Matrix Builds)

**Purpose:** Additional libFuzzer builds covering the full arch × sanitizer matrix for comprehensive testing across all sanitizer configurations.

**Implementation:** [pipelines/preprocessing.yaml:702-793](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L702-L793)

**Configuration:**

- **Instrumentation:** libFuzzer
- **Debug Symbols:** `-gline-tables-only` (same as canonical build)
- **Sanitizer:** Per `build_configuration` (address, undefined, memory, thread)
- **Architecture:** Per `build_configuration` (currently x86_64 only)
- **Priority:** 2 (lower than canonical)
- **Multiplicity:** **One build per (arch × sanitizer) combination**

**Task Instantiation Logic:**

The `debug_build` task is instantiated once for each `BuildConfiguration` object via the pydatatask `InputMetadata` mechanism ([Line 714-716](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L714-L716)).

The Configuration Splitter creates these configurations using a nested loop ([split_configurations.py:55-72](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/configuration-splitter/split_configurations.py#L55-L72)):

```python
for architecture in meta.architectures:
    if architecture not in SUPPORTED_ARCHES:
        continue
    for sanitizer in meta.sanitizers:
        if sanitizer not in SUPPORTED_SANITIZERS:
            continue
        model = BuildConfiguration(
            project_id=ARGS.project_id,
            project_name=meta.get_project_name(),
            sanitizer=sanitizer,
            architecture=architecture,
        )
        config_key = build_configs_repo.upload_dedup(model.model_dump_json(indent=2))
        configs[config_key] = model
```

This creates `len(architectures) × len(sanitizers)` configurations, and the debug_build task runs once for each configuration.

**Key Differences from Canonical:**

The debug build is functionally identical to canonical build in terms of compilation flags. Both include line-table debug information via [Dockerfile.prebuild:43](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/shellphish_libfuzzer/Dockerfile.prebuild#L43):

```dockerfile
ENV CFLAGS -O1 \
  -fno-omit-frame-pointer \
  -gline-tables-only \
  ...
```

**Behavioral Differences:**

| Aspect | Canonical Build | Debug Build |
|--------|----------------|-------------|
| Input metadata | `base_meta` ([Line 528](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L528)) | `build_configuration` ([Line 714](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L714)) |
| Architecture | Hardcoded `x86_64` ([Line 579](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L579)) | From `build_configuration.architecture` ([Line 777](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L777)) |
| Sanitizer | First from `base_meta.sanitizers` ([Line 580](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L580)) | From `build_configuration.sanitizer` ([Line 778](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L778)) |
| Number of builds | 1 per project | N per project (N = arch × sanitizer combinations) |
| Priority | 20B (highest) | 2 (low) |
| Output repository | `canonical_build_artifacts` | `debug_build_artifacts` |

**Sanitizer Matrix:**

The debug builds are created based on the project's `sanitizers` field in `project.yaml` ([OSSFuzzProjectYAML model](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/models/oss_fuzz.py#L62)), filtered by [SUPPORTED_SANITIZERS](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/configuration-splitter/split_configurations.py#L17):

**For C/C++ Projects:**

Default sanitizers: `['address', 'undefined']`

Supported sanitizers:
- **AddressSanitizer (address)** - Detects memory errors (buffer overflows, use-after-free, heap/stack/global buffer overflows)
- **UndefinedBehaviorSanitizer (undefined)** - Catches undefined behavior (signed integer overflow, misaligned pointers, null pointer dereference)
- **MemorySanitizer (memory)** - Detects uninitialized memory reads (opt-in only)
- **ThreadSanitizer (thread)** - Identifies data races and threading issues (opt-in only)

**For Java/JVM Projects:**

Default sanitizers: `['address', 'undefined']` (same as C/C++)

Java-specific behavior:
- **AddressSanitizer** can be used for JNI/native code portions when Jazzer fuzzes hybrid Java+native applications (via [Jazzer's native library support](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/notes/src/whitepaper/Artiphishell-3.md#:~:text=fuzz%20across%20this%20language%20boundary))
- Build configurations are created the same way as C/C++, though sanitizer effectiveness depends on native code presence

**Example:** For a project with default configuration on x86_64:
- **Canonical:** 1 build (x86_64 + address)
- **Debug:** 2 builds (x86_64 + address, x86_64 + undefined)

**Artifacts:**

- Symbol tables for stack trace resolution
- Line-table debugging information (function names, file:line mappings)
- Source-to-binary mapping

### 3. Coverage Build

**Purpose:** Generate detailed coverage reports for specific seeds.

**For C/C++ Projects** ([pipelines/preprocessing.yaml:888-977](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L888-L977)):

- **Instrumentation:** `shellphish_coverage`
- **Output:** Line and branch coverage data
- **Format:** LLVM coverage profiles

**For Java Projects** ([pipelines/preprocessing.yaml:980-1066](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L980-L1066)):

- **Instrumentation:** Jazzer with coverage
- **Output:** JaCoCo-compatible coverage reports

### 4. Delta Mode Builds (Java Only)

**Purpose:** Build HEAD~1 version for differential analysis in patch verification.

**Implementation:** [pipelines/preprocessing.yaml:597-700](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L597-L700)

**Trigger:** Only runs when `delta_mode_tasks` input exists

**Process:**

- Builds base version (HEAD~1) via `--git-ref "HEAD~1"`
- Allows comparison of vulnerability presence before/after patch
- Stores in separate `canonical_build_delta_artifacts` repository
- Tracks failures in `canonical_build_delta_failures`

## OSS-Fuzz Integration

### Build Infrastructure

**Image Creation:**

- `oss-fuzz-build-image` creates builder images with all dependencies
- `--build-runner-image` flag creates minimal runtime images
- Images pushed to registry when `IN_K8S` environment variable set

**Build Process:**

- Uses OSS-Fuzz project structure (Dockerfile, build.sh, harnesses)
- Supports multiple languages: C, C++, Java
- Handles complex build systems (CMake, Bazel, Maven, etc.)

### Instrumentations Supported

**libFuzzer:** Coverage-guided fuzzing for C/C++

**Jazzer:** Coverage-guided fuzzing for Java/JVM languages

**shellphish_codeql:** CodeQL database generation

**shellphish_coverage:** Coverage reporting

### Sanitizers

**AddressSanitizer (ASan):** Detects memory errors (buffer overflows, use-after-free)

**UndefinedBehaviorSanitizer (UBSan):** Catches undefined behavior

**MemorySanitizer (MSan):** Detects uninitialized memory reads

**ThreadSanitizer (TSan):** Identifies data races and threading issues

## Build Artifacts

### Directory Structure

Directory structure defined by [OSSFuzzProject properties](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/project.py#L283-L292):

```text
artifacts/                         # artifacts_dir (Line 283-284)
├── out/                           # Harness binaries (artifacts_dir_out, Line 291-292)
│   ├── harness1                   # Fuzzer executable
│   ├── harness1.shellphish_harness_symbols.json  # Symbol info (generated by llvm-symbolizer)
│   └── ...
├── work/                          # Intermediate build files (artifacts_dir_work, Line 287-288)
│   ├── sss-codeql-database.zip    # CodeQL database (if applicable)
│   └── ...
├── built_src/                     # Source code (artifacts_dir_built_src, Line 295-300)
│   └── ...                        # Only when --preserve-built-src-dir is set
├── builder_image                  # Docker builder image name
├── runner_image                   # Docker runtime image name
└── shellphish_build_metadata.yaml # Build metadata
```

**Harness Symbol Generation** ([project.py:1011](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/project.py#L1011)):
```bash
llvm-symbolizer --obj="$harness" --output-style=JSON "$harness_address" \
  > "$harness.shellphish_harness_symbols.json"
```

**Image Name Storage** ([preprocessing.yaml:590-591](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L590-L591)):
```bash
echo "${BUILDER_IMAGE}" >> "${OSS_FUZZ_PROJECT_DIR}/artifacts/builder_image"
echo "${RUNNER_IMAGE}" >> "${OSS_FUZZ_PROJECT_DIR}/artifacts/runner_image"
```

### Metadata Format

`shellphish_build_metadata.yaml` format defined in [project.py:1158-1169](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/project.py#L1158-L1169):

```yaml
harnesses: [harness1, harness2, ...]  # List of harness names
architecture: x86_64                   # Target architecture
source_repo_path: /src/project         # Builder workdir path
project_name: project-name             # OSS-Fuzz project name
sanitizer: address                     # Sanitizer used for this build
fuzzing_engine: libfuzzer              # Fuzzing engine (libfuzzer/afl/etc)
```

## Task Service Architecture

### Containerized Execution

All builds run in isolated containers with:

- **Base Image:** `aixcc-component-base`
- **Docker Socket:** Mounted for nested container operations
- **Shared Storage:** `/shared/` (hostPath volume, [permanence/values.yaml:65-67](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/infra/k8/charts/services/permanence/values.yaml#L65-L67)) for cross-task data access (e.g., ccache)

### Resource Management

**Priority System:**

- Canonical build: 20B (highest priority, [preprocessing.yaml:507](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L507))
- Debug builds: 2 (lower priority, [preprocessing.yaml:708](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L708))
- Coverage builds: Lower priority (after canonical completes)

Note: CodeQL analysis (part of Analyzer phase, not Bob the Builder) also runs with priority 20B and executes in parallel with canonical build.

**Resource Quotas:**

- Initial: 0.5 CPU, 500Mi RAM (task controller overhead)
- Actual build: 6-10 CPU, 26-40Gi RAM (via oss-fuzz-build parameters)

**Scalability:**

- Auto-scaling based on workload
- Preemption for higher-priority tasks
- Kubernetes-based orchestration when `IN_K8S` set

### Failure Handling

**Exit Codes:**

- Exit 0: Success, artifacts uploaded
- Exit 1: General failure (no artifacts)
- Exit 33: Specific failure condition (triggers retry)

**Retry Logic:**

- Builder image creation failures retry with different parameters
- Build failures logged to `canonical_build_delta_failures`

## Integration with Preprocessing Pipeline

### Inputs

- `crs_tasks` - Task metadata with project name and ID
- `crs_tasks_oss_fuzz_repos` - OSS-Fuzz repository with Dockerfile and build scripts
- `base_project_metadatas` - Project configuration (sanitizers, architectures)

### Outputs

**To Analyzer:**

- `canonical_build_artifacts` - Contains harness symbols for detection
- `debug_build_artifacts` - Debug symbols for analysis
- Build metadata with harness list

**To Vulnerability Analysis:**

- Instrumented binaries for fuzzing
- Coverage builds for seed evaluation

**To Indexer:**

- Source tree structure in `artifacts/src/`
- Build artifacts for function extraction

## Environment Variables

`CRS_TASK_NUM`: Concurrent task identifier for logging

`IN_K8S`: Kubernetes deployment flag (enables image pushing)

`INITIAL_BUILD_CPU/MEM`: Initial resource allocation

`INITIAL_BUILD_MAX_CPU/MAX_MEM`: Maximum scalable resources

## Performance Characteristics

**Build Timeout:**

- Maximum build time: 180 minutes ([preprocessing.yaml:509](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L509))
- Builds exceeding timeout are terminated and marked as failed

**Parallelism:**

- Multiple builds can run simultaneously
- Independent per-project task scheduling
- Resource-aware auto-scaling

**Storage:**

- Compressed tar archives for filesystem repositories
- Deduplication via content-addressable storage
- Typical artifact size: 100Mi-10Gi per build

## Note on AFL++ and Jazzer Builds

The whitepaper ([Section 4.1](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/notes/src/whitepaper/Artiphishell-3.md#41-bob-the-builder)) mentions "AFLuzzer build" and "Jazzmine build" as part of Bob the Builder. However, in the actual implementation, these builds are **not part of the preprocessing phase**. Instead, they are separate components in the vulnerability identification phase:

**AFL++ Build (C/C++ projects):**

- **Implementation:** [components/aflplusplus/pipeline.yaml:35-91](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/aflplusplus/pipeline.yaml#L35-L91)
- **Instrumentation:** `shellphish_aflpp` ([instrumentation class](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflpp/__init__.py#L12-L14))
- **Integrated in:** `targets-c.yaml` pipeline ([Line 56-73](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/targets-c.yaml#L56-L73))
- **Priority:** 150 (lower than preprocessing builds)
- **Purpose:** Provides AFL++-instrumented builds specifically for the AFL++ fuzzing component
- **Output Repository:** `aflpp_build_artifacts`

**Jazzer Build (Java projects):**

- **Implementation:** [components/jazzer/pipeline.yaml:32-150](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L32-L150)
- **Instrumentation:** `shellphish_jazzer` ([instrumentation class](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/jazzer/__init__.py#L16-L17))
- **Integrated in:** `targets-java.yaml` pipeline ([Line 67-88](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/targets-java.yaml#L67-L88))
- **Priority:** 150
- **Purpose:** Provides Jazzer-instrumented builds specifically for the Jazzer fuzzing component
- **Output Repositories:** `jazzer_build_artifacts`, `jazzer_build_shellphish_dir`

**Architectural Rationale:**

The separation of AFL++ and Jazzer builds from Bob the Builder makes sense from a design perspective:

1. **Conditional Execution:** These builds are only needed when their respective fuzzing components are active
2. **Lower Priority:** Unlike canonical/debug builds (priority 20B-2), these fuzzing-specific builds run at priority 150
3. **Fuzzer-Specific:** AFL++ builds are C/C++-specific, Jazzer builds are Java-specific, while Bob the Builder handles both languages
4. **Dependency Management:** Vulnerability identification components can depend directly on their specific build artifacts

**Whitepaper vs Implementation:**

The whitepaper presents a conceptual view where "Bob the Builder" is responsible for all build artifacts. In practice, Bob the Builder (preprocessing phase) creates the core builds needed by multiple components (canonical, debug, coverage), while language/fuzzer-specific builds are handled by their respective components in the vulnerability identification phase.
