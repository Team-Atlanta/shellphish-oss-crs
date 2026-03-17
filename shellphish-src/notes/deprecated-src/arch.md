# ARTIPHISHELL CRS Architecture Diagram

```mermaid
graph TB
    %% External APIs and Services
    subgraph "External Services"
        CompAPI[Competition API]
        LLMs[LLM Services<br/>OpenAI/Anthropic/Gemini]
        Azure[Azure Infrastructure]
    end

    %% Input Layer
    subgraph "Input & Target Analysis"
        TargetID[Target Identifier]
        DiscoveryGuy[Discovery Guy]
        ProjectMeta[Project Metadata]
        TargetID --> ProjectMeta
        DiscoveryGuy --> ProjectMeta
    end

    %% Static Analysis Layer
    subgraph "Static Analysis"
        CodeQL[CodeQL Server]
        Semgrep[Semgrep]
        ClangIdx[Clang Indexer]
        FuncIdx[Function Index<br/>Generator]
        CodeChecker[CodeChecker]

        ProjectMeta --> CodeQL
        ProjectMeta --> Semgrep
        ProjectMeta --> ClangIdx
        ClangIdx --> FuncIdx
    end

    %% Grammar Generation Layer
    subgraph "Grammar & Input Generation"
        GrammarGuy[Grammar Guy<br/>LLM-Powered]
        GrammarComp[Grammar Composer]
        ANTLR4[ANTLR4 Guy]
        Grammaroomba[Grammaroomba]
        QuickSeed[QuickSeed]
        CorpusGuy[Corpus Guy]

        LLMs -.-> GrammarGuy
        CodeQL --> GrammarGuy
        FuncIdx --> GrammarGuy
        GrammarGuy --> GrammarComp
        ANTLR4 --> GrammarComp
        GrammarComp --> Grammaroomba
        Grammaroomba --> CorpusGuy
        QuickSeed --> CorpusGuy
    end

    %% Fuzzing Layer
    subgraph "Fuzzing Engines"
        AFL[AFL++]
        LibFuzz[LibFuzzer]
        Jazzer[Jazzer<br/>JVM Fuzzing]
        Snapchange[Snapchange<br/>Snapshot Fuzzing]
        ClusterFuzz[ClusterFuzz]

        CorpusGuy --> AFL
        CorpusGuy --> LibFuzz
        CorpusGuy --> Jazzer
        CorpusGuy --> Snapchange
        HarnessDen[Harness Den] --> AFL
        HarnessDen --> LibFuzz
    end

    %% Coverage & Monitoring
    subgraph "Coverage & Monitoring"
        CoverageGuy[Coverage Guy]
        TelemetryDB[(Telemetry DB<br/>InfluxDB)]
        Grafana[Grafana<br/>Dashboard]

        AFL --> CoverageGuy
        LibFuzz --> CoverageGuy
        Jazzer --> CoverageGuy
        CoverageGuy --> TelemetryDB
        TelemetryDB --> Grafana
        CoverageGuy --> GrammarGuy
    end

    %% Crash Analysis Layer
    subgraph "Crash Analysis"
        CrashTrace[Crash Tracer]
        CrashExplore[Crash Exploration]
        InvariantGuy[Invariant Guy]
        KumuShi[Kumu-Shi Runner]

        AFL --> CrashTrace
        LibFuzz --> CrashTrace
        Jazzer --> CrashTrace
        Snapchange --> CrashTrace
        CrashTrace --> CrashExplore
        CrashTrace --> InvariantGuy
        InvariantGuy --> KumuShi
    end

    %% AI Analysis Layer
    subgraph "AI/ML Analysis"
        AIJON[AIJON<br/>AI Orchestrator]
        DyVA[DyVA<br/>Dynamic Analysis]
        VulnModel[Vuln Detect Model]

        LLMs -.-> AIJON
        CrashExplore --> AIJON
        AIJON --> DyVA
        AIJON --> VulnModel
        CodeQL --> VulnModel
    end

    %% POV Generation
    subgraph "POV Generation"
        POVGuy[POV Guy]
        POVPatrol[POV Patrol]
        POIGen[Points of Interest]

        CrashExplore --> POVGuy
        KumuShi --> POIGen
        POVGuy --> POVPatrol
        POIGen --> POVPatrol
    end

    %% Patching Layer
    subgraph "Patching System"
        PatcherY[PatcherY<br/>Orchestrator]
        PatcherG[PatcherG<br/>Grammar-based]
        PatcherQ[PatcherQ<br/>Multi-Agent]

        subgraph "PatcherQ Agents"
            ProgGuy[Programmer Guy]
            TriageGuy[Triage Guy]
            CriticGuy[Critic Guy]
            DiffGuy[Diff Guy]
        end

        POIGen --> PatcherY
        AIJON --> PatcherY
        VulnModel --> PatcherY

        PatcherY --> PatcherG
        PatcherY --> PatcherQ

        PatcherQ --> ProgGuy
        PatcherQ --> TriageGuy
        ProgGuy --> CriticGuy
        CriticGuy --> DiffGuy

        LLMs -.-> ProgGuy
        LLMs -.-> TriageGuy
        LLMs -.-> CriticGuy
    end

    %% Validation & Testing
    subgraph "Validation & Testing"
        TestGuy[TestGuy]
        PatchVal[Patch Validation<br/>Testing]
        SarifGuy[SARIF Guy]

        DiffGuy --> TestGuy
        PatcherG --> TestGuy
        TestGuy --> PatchVal
        CodeQL --> SarifGuy
        Semgrep --> SarifGuy
        SarifGuy --> PatchVal
    end

    %% Submission Layer
    subgraph "Submission"
        Submitter[Submitter]
        BackdoorGuy[Backdoor Guy<br/>Security Check]

        POVPatrol --> Submitter
        PatchVal --> Submitter
        Submitter --> BackdoorGuy
        BackdoorGuy --> CompAPI
    end

    %% Data Repositories (shown as storage)
    subgraph "Data Repositories"
        MetaRepo[(Metadata<br/>Repository)]
        BlobRepo[(Blob<br/>Repository)]
        FileRepo[(Filesystem<br/>Repository)]
    end

    %% Key data flows
    CrashTrace -.-> MetaRepo
    POVGuy -.-> BlobRepo
    PatcherY -.-> FileRepo
    MetaRepo -.-> Submitter
    BlobRepo -.-> Submitter

    %% Pipeline Orchestration
    Pipeline[Pipeline<br/>Orchestrator] --> TargetID
    Pipeline --> AFL
    Pipeline --> PatcherY
    Pipeline --> Submitter

    style LLMs fill:#f9f,stroke:#333,stroke-width:2px
    style CompAPI fill:#9f9,stroke:#333,stroke-width:2px
    style GrammarGuy fill:#ff9,stroke:#333,stroke-width:2px
    style PatcherY fill:#9ff,stroke:#333,stroke-width:2px
    style AIJON fill:#f9f,stroke:#333,stroke-width:2px
```

## Architecture Overview

### Data Flow Description

1. **Target Analysis Phase**
   - Target Identifier and Discovery Guy analyze the target application
   - Project metadata is generated and stored
   - Static analysis tools (CodeQL, Semgrep, Clang) create code intelligence

2. **Grammar Generation Phase**
   - Grammar Guy uses LLMs and coverage feedback to generate input grammars
   - Grammar Composer combines multiple grammar sources
   - Corpus Guy manages seed inputs for fuzzing

3. **Fuzzing Phase**
   - Multiple fuzzing engines (AFL++, LibFuzzer, Jazzer, Snapchange) run in parallel
   - Coverage Guy tracks code coverage and feeds back to Grammar Guy
   - Telemetry is collected in InfluxDB and visualized in Grafana

4. **Crash Analysis Phase**
   - Crash Tracer analyzes execution paths leading to crashes
   - Invariant Guy extracts program invariants
   - Kumu-Shi Runner performs root cause analysis

5. **AI Analysis Phase**
   - AIJON orchestrates AI-based analysis
   - DyVA performs dynamic vulnerability analysis
   - Vulnerability detection models classify and prioritize findings

6. **POV Generation Phase**
   - POV Guy generates proof-of-vulnerability exploits
   - Points of Interest are identified for patching
   - POV Patrol validates and manages submissions

7. **Patching Phase**
   - PatcherY orchestrates multiple patching strategies
   - PatcherQ uses multi-agent LLM approach (Programmer, Triage, Critic, Diff agents)
   - PatcherG applies grammar-based transformations

8. **Validation Phase**
   - TestGuy runs comprehensive tests on patches
   - SARIF Guy processes static analysis results
   - Patch validation ensures functionality preservation

9. **Submission Phase**
   - Submitter handles API interactions
   - Backdoor Guy performs security checks
   - Validated patches and POVs are submitted to Competition API

### Key Interactions

- **LLM Integration**: Dotted lines show LLM API calls for intelligent decision-making
- **Coverage Feedback Loop**: Coverage data flows back to Grammar Guy for refinement
- **Repository Layer**: All components interact with centralized data repositories
- **Pipeline Orchestration**: Central pipeline controller manages task scheduling and dependencies

### Component Categories

- **Pink**: AI/LLM-powered components
- **Yellow**: Grammar and input generation
- **Cyan**: Patching and remediation
- **Green**: External APIs and submission
- **White**: Traditional analysis and fuzzing tools
