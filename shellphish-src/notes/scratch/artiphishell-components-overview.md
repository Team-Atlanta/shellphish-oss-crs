# ARTIPHISHELL CRS Components Overview

## What is ARTIPHISHELL?

ARTIPHISHELL is a Cyber Reasoning System (CRS) designed for the AI Cyber Challenge (AFC) that performs LLM-based vulnerability detection and automated patching. The system combines traditional fuzzing techniques with modern AI/LLM capabilities to identify and fix security vulnerabilities in software.

## Core Architecture

The system is built on a microservices architecture with components deployed via Kubernetes/Helm on Azure. Components communicate through a pipeline system with various repositories for storing metadata, analysis results, and artifacts.

## Major Component Categories

### Fuzzing and Testing Components

**AFL++ (`components/aflplusplus`)**
The classic American Fuzzy Lop fuzzer, enhanced version, used as a core fuzzing engine for vulnerability discovery.

**LibFuzzer (`components/libfuzzer`)**
Google's in-process, coverage-guided fuzzing engine integrated for targeted vulnerability detection.

**Jazzer (`components/jazzer`)**
A coverage-guided fuzzer for the JVM, bringing fuzzing capabilities to Java applications.

**Snapchange (`components/snapchange`)**
A snapshot-based fuzzing framework using QEMU for efficient state restoration during fuzzing campaigns.

**Clusterfuzz (`components/clusterfuzz`)**
Google's scalable fuzzing infrastructure, adapted for distributed fuzzing operations.

### Grammar and Input Generation

**Grammar-Guy (`components/grammar-guy`)**
The primary grammar generation component that uses coverage feedback to create and refine input grammars. It interfaces with LLMs to generate tailored grammars for reaching specific code paths. Key features include:
- Coverage-guided grammar refinement
- Integration with nautilus and grammarinator fuzzers
- LLM-based grammar improvement
- Support for various sanitizers (OSCommandInjection, FilePathTraversal, etc.)

**Grammar-Composer (`components/grammar-composer`)**
Combines and optimizes multiple grammars into unified input generation strategies.

**ANTLR4-Guy (`components/antlr4-guy`)**
Handles ANTLR4 grammar parsing and manipulation for structured input generation.

**Grammaroomba (`components/grammaroomba`)**
Automated grammar cleaning and optimization component.

**Syzgrammar-Gen (`components/syzgrammar-gen`)**
Generates syzkaller-compatible grammars for kernel fuzzing.

### Patching and Remediation

**PatcherY (`components/patchery`)**
The main patching orchestrator that coordinates vulnerability fixes across different patching strategies.

**PatcherG (`components/patcherg`)**
Grammar-based patching component focused on structural code transformations.

**PatcherQ (`components/patcherq`)**
Contains multiple specialized agents:
- programmerGuy: Generates patches
- triageGuy: Analyzes vulnerabilities
- criticGuy: Reviews patch quality
- diffGuy: Manages patch differences
- issueGuy: Tracks patching issues

### Static Analysis and Code Intelligence

**CodeQL (`components/codeql`)**
GitHub's semantic code analysis engine with custom CWE queries for vulnerability detection. Includes specialized query packs for kernel and Jenkins analysis.

**Clang-Indexer (`components/clang-indexer`)**
Creates searchable indexes of C/C++ codebases for rapid code navigation.

**Clang-Instrumentation (`components/clang-instrumentation`)**
Adds runtime instrumentation to programs for enhanced monitoring and analysis.

**Semgrep (`components/semgrep`)**
Pattern-based static analysis for finding bug patterns and security issues.

**CodeChecker (`components/codechecker`)**
Static analysis result management and visualization tool.

### AI/LLM Components

**AIJON (`components/aijon`)**
Core AI component for coordinating LLM-based analysis and decision-making.

**DyVA (`components/dyva`)**
Dynamic vulnerability analysis using AI techniques.

**Vuln-Detect-Model (`components/vuln_detect_model`)**
Machine learning models specifically trained for vulnerability detection patterns.

**Invariant-Guy (`components/invariant-guy`)**
Extracts and validates program invariants using:
- java_guy: Java invariant extraction
- kernel_guy: Kernel invariant extraction
- c_guy: C/C++ invariant extraction

### Corpus and Coverage Management

**Corpus-Guy (`components/corpus-guy`)**
Manages fuzzing input corpora, deduplicates seeds, and optimizes corpus quality.

**Coverage-Guy (`components/coverage-guy`)**
Tracks and analyzes code coverage metrics to guide fuzzing efforts.

**Quickseed (`components/quickseed`)**
Rapidly generates initial seed inputs for fuzzing campaigns.

### Crash Analysis and Exploration

**Crash-Tracer (`components/crash-tracer`)**
Traces execution paths leading to crashes for root cause analysis.

**Crash-Exploration (`components/crash_exploration`)**
Explores crash variations to understand vulnerability boundaries.

**POV-Guy (`components/povguy`)**
Generates Proof of Vulnerability exploits from crashes.

**POV-Patrol (`components/pov-patrol`)**
Validates and manages POV submissions.

**Kumu-Shi-Runner (`components/kumu-shi-runner`)**
Runs targeted vulnerability analysis workflows.

### Support Components

**Submitter (`components/submitter`)**
Handles submission of patches and POVs to the competition API.

**TestGuy (`components/testguy`)**
Comprehensive testing framework for validating patches and ensuring functionality.

**SarifGuy (`components/sarifguy`)**
Processes SARIF (Static Analysis Results Interchange Format) reports from various tools.

**DiscoveryGuy (`components/discoveryguy`)**
Discovers and identifies vulnerable components in target applications.

**Target-Identifier (`components/target-identifier`)**
Identifies and classifies fuzzing targets within applications.

**Harness-Den (`components/harness-den`)**
Repository of fuzzing harnesses for different target types.

**Function-Index-Generator (`components/function-index-generator`)**
Creates searchable indexes of function definitions across codebases.

## Supporting Services

**Analysis Graph (`services/analysis_graph`)**
Maintains relationships between analysis artifacts and results.

**CodeQL Server (`services/codeql_server`)**
Provides CodeQL analysis as a service.

**Function Resolver Server (`services/functionresolver_server`)**
Resolves function locations and signatures across the codebase.

**Language Server (`services/lang-server`)**
Provides language-specific code intelligence features.

**VLLM (`services/vllm`)**
Serves large language models for various AI-powered components.

**Telemetry DB (`services/telemetry_db`)**
InfluxDB instance for storing performance metrics and telemetry.

**Grafana (`services/grafana`)**
Visualization dashboards for monitoring CRS performance and fuzzing progress.

## Pipeline Architecture

The system uses a sophisticated pipeline architecture defined in `pipeline.yaml` files that:
- Defines task dependencies and execution order
- Manages resource allocation (CPU, memory)
- Controls concurrent job limits
- Specifies node affinity and taints for specialized workloads
- Handles data flow between components via various repository types (MetadataRepository, FilesystemRepository, BlobRepository)

## LLM Integration

The system extensively uses LLMs (OpenAI, Anthropic, Gemini) for:
- Grammar generation and refinement
- Vulnerability analysis and triage
- Patch generation and validation
- Code understanding and navigation
- Bug report generation

## Key Innovations

1. **LLM-Guided Fuzzing**: Grammar-Guy uses LLMs to intelligently generate and refine input grammars based on coverage feedback.

2. **Automated Patching Pipeline**: Multiple patching strategies (PatcherY, PatcherG, PatcherQ) work together to generate, validate, and submit fixes.

3. **Comprehensive Analysis**: Combines static analysis (CodeQL, Semgrep), dynamic analysis (fuzzing), and AI-based analysis for thorough vulnerability detection.

4. **Scalable Infrastructure**: Cloud-native deployment on Azure with Kubernetes enables massive parallel fuzzing and analysis.

5. **Multi-Language Support**: Components for C/C++, Java, and kernel code analysis provide broad coverage.

The ARTIPHISHELL CRS represents a sophisticated integration of traditional security analysis techniques with modern AI capabilities, designed specifically for the automated vulnerability discovery and remediation challenges of the AI Cyber Challenge.