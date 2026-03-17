# Infrastructure

The CRS infrastructure provides the foundational layer for orchestrating distributed analysis, managing state, and coordinating workflows across the entire bug-finding and patch-generation pipeline.

## Core Components

1. **[PyDataTask](./infrastructure/pydatatask.md)** - Task orchestration framework
2. **[Analysis Graph](./infrastructure/analysis-graph.md)** - Neo4j-based knowledge graph
3. **[Scheduling & Execution](./infrastructure/scheduling.md)** - Distributed job management
4. **[Repository System](./infrastructure/repositories.md)** - Storage abstraction layer

## Overview

```mermaid
graph TD
    A[PyDataTask Pipeline] -->|Schedules| B[Kubernetes Jobs]
    A -->|Reads/Writes| C[Repositories]
    B -->|Uploads Coverage| D[Analysis Graph]
    B -->|Uploads POVs| D
    B -->|Uploads Patches| D
    D -->|Queries| E[Neo4j Database]
    C -->|S3/Filesystem| F[Blob Storage]
    C -->|MongoDB| G[Metadata Storage]
    D -->|Provides Context| H[LLM Agents]
    H -->|PatcherQ/AIJON/etc| I[Bug Finding & Patching]
```

## PyDataTask Architecture

**PyDataTask** is the core orchestration framework that drives the entire CRS pipeline. It provides:

- **Task Abstraction**: Units of computation parameterized by jobs
- **Repository System**: Flexible key-value storage (S3, MongoDB, filesystem)
- **Link System**: Connects tasks to repositories with input/output relationships
- **Pipeline**: Implicit dependencies through shared repositories
- **Execution Modes**: Local, SSH, Docker, Kubernetes

**Key Concept**: Tasks declare their data dependencies through "links" to repositories. The pipeline automatically infers execution order based on which repositories tasks share.

## Analysis Graph Architecture

The **Analysis Graph** is a Neo4j-based knowledge graph that tracks:

- **Coverage**: Function-level coverage relationships
- **POVs**: Crash reports, deduplication, representative inputs
- **Patches**: Generated patches, verification results
- **Relationships**: Input → Coverage → Function, POV → Patch, etc.

**Key Features**:
- Concurrent write handling with transaction retries
- Unique identifier-based deduplication
- Function resolver integration for coverage tracking
- Grammar-to-function coverage mapping

## Scheduling & Execution

The CRS uses **Kubernetes** for distributed execution:

- **Pipeline YAML**: Declarative task definitions with resource quotas
- **Pod Manager**: Schedules jobs on Kubernetes cluster
- **Job Quota**: CPU, memory, GPU, max concurrent jobs
- **Priority System**: High-priority tasks (patches) vs background tasks (static analysis)
- **Failure Handling**: `failure_ok`, `require_success`, `long_running` modes

**Example Pipeline Task**:
```yaml
patcherq_patch_mode:
  job_quota:
    cpu: 4
    mem: "8Gi"
    gpu: 1
  priority: 100000
  max_concurrent_jobs: 50

  links:
    poi_report:
      repo: poi_reports
      kind: InputFilepath
    patch_diff:
      repo: patch_diffs
      kind: OutputFilepath
```

## Repository System

**Repositories** abstract storage with multiple backends:

- **BlobRepository**: S3 buckets, local filesystem
- **MetadataRepository**: MongoDB, YAML files
- **StreamingRepository**: Continuous data flows (e.g., coverage updates)
- **DockerRepository**: Container images

**Key Operations**:
- `get_or_none(key)`: Fetch metadata
- `open(key, mode)`: Stream blob data
- `keys()`: Query available jobs
- `inhibits()`: Block dependent tasks

## Data Flow Example

**POV Generation → Patch Generation**:

1. **POVGuy** runs → uploads POV to `pov_reports` repository
2. **POIGuy** reads POV from `pov_reports` → uploads POI to `poi_reports`
3. **PatcherQ** reads POI from `poi_reports` → generates patch → uploads to `patch_diffs`
4. **PatcherG** reads patches from `patch_diffs` → scores and submits

**Each step**:
- Reads from input repositories (task blocked until data available)
- Processes data
- Writes to output repositories (unblocks downstream tasks)
- Updates Analysis Graph with metadata

## Performance Characteristics

- **Neo4j Write Transactions**: Automatic retry on conflict
- **Kubernetes Scheduling**: Priority-based with resource quotas
- **S3 Streaming**: Async I/O with aiobotocore
- **MongoDB Queries**: Indexed by `pdt_project_id`, `harness_info_id`
- **Coverage Upload**: ~720 seeds/min (C/C++), ~240 seeds/min (Java)

## Configuration

**Analysis Graph Connection** ([analysis_graph/__init__.py:5](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/__init__.py#L5)):
```python
config.DATABASE_URL = os.environ.get(
    'ANALYSIS_GRAPH_BOLT_URL',
    'bolt://neo4j:helloworldpdt@aixcc-analysis-graph:7687'
)
```

**PyDataTask Pipeline** ([pipeline.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherq/pipeline.yaml)):
```yaml
session:
  bucket_endpoint: "${BUCKET_ENDPOINT}"
  bucket_username: "${BUCKET_USERNAME}"
  bucket_password: "${BUCKET_PASSWORD}"
  mongodb_url: "${MONGODB_URL}"
```

## Related Components

All components in the CRS depend on this infrastructure:

- **[Bug Finding](./bug-finding.md)**: Uses PyDataTask pipelines, uploads to Analysis Graph
- **[Patch Generation](./patch-generation.md)**: Queries Analysis Graph, orchestrated by PyDataTask
- **[SARIF Processing](./sarif-processing.md)**: Uploads validated findings to Analysis Graph
