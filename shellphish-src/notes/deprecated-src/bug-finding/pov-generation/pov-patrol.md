# POV-Patrol

POV-Patrol **validates patches against POVs** by running them in parallel to determine if patches mitigate vulnerabilities. It operates in two modes: testing a single POV against all patches, or testing a single patch against all POVs.

## Purpose

- Parallel POV testing (3 workers)
- Patch artifact downloading and caching
- Mitigated/non-mitigated classification
- Analysis graph integration
- 120-second timeout per POV-patch comparison
- Retry mechanism (3 attempts per comparison)

## Implementation

**Main File**: [`pov_patch_check.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pov_patch_check.py)

**Pipeline**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pipeline.yaml)

## Two Modes

### POV Mode ([Lines 88-93](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pipeline.yaml#L88-L93))

**Test one POV against all patches**:

```bash
python3 /pov-patrol/pov_patch_check.py \
    --project-id $PROJECT_ID \
    --oss-fuzz-project-folder $OSS_FUZZ_REPO/projects/$PROJECT_NAME \
    --mode pov \
    --pov-report-id $POV_REPORT_ID \
    --crashing-input $CRASHING_INPUT_PATH
```

**Workflow** ([Lines 121-215](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pov_patch_check.py#L121-L215)):
1. Query all patches for project from Analysis Graph
2. Get POV metadata (harness name, sanitizer)
3. For each patch:
   - Download patch artifacts (cached in `/shared`)
   - Copy to temporary OSS-Fuzz project
   - Run POV 3 times (retry on failure)
   - Connect to `mitigated_povs` or `non_mitigated_povs` relationship

### Patch Mode ([Lines 166-170](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pipeline.yaml#L166-L170))

**Test one patch against all POVs**:

```bash
python3 /pov-patrol/pov_patch_check.py \
    --project-id $PROJECT_ID \
    --oss-fuzz-project-folder $OSS_FUZZ_REPO/projects/$PROJECT_NAME \
    --mode patch \
    --patch-id $PATCH_ID
```

**Workflow** ([Lines 271-355](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pov_patch_check.py#L271-L355)):
1. Query all POVs for project from Analysis Graph
2. Get patch node and artifacts
3. Copy patch artifacts to OSS-Fuzz project
4. **Parallel processing** with 3 workers:
   - Each worker tests one POV against the patched binary
   - 120-second timeout per POV-patch comparison
   - 3 retries on failure
5. Update Analysis Graph with results

## Patch Artifact Management

### Download and Cache ([Lines 29-61](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pov_patch_check.py#L29-L61))

```python
SHARED_ARTIFACTS_DIR = Path(f"/shared/pov_patrol") / os.environ.get('PROJECT_ID','all')

def get_patch_artifacts(patch_key: str, build_request_id: str, pd_client: PDClient) -> Path:
    artifacts_dir = SHARED_ARTIFACTS_DIR / str(patch_key)
    if artifacts_dir.exists():
        return artifacts_dir  # Use cached artifacts

    logger.info("Getting patch artifacts for %s, build request id %s", patch_key, build_request_id)
    for _ in range(3):  # 3 retries
        try:
            artifacts_dir.mkdir(parents=True, exist_ok=True)

            with tempfile.TemporaryDirectory() as tmp_dir:
                out_file_path = Path(tmp_dir) / "build_artifacts.tar.gz"
                BuildServiceRequest.keyed_download_build_artifacts_tar(
                    client=pd_client,
                    request_id=build_request_id,
                    out_file_path=out_file_path
                )

                shutil.unpack_archive(out_file_path, artifacts_dir)
            break
        except AssertionError as e:
            logger.error("Error getting patch artifacts for %s: %s", patch_key, e)
            time.sleep(10)
    else:
        raise ValueError(f"Failed to get patch artifacts for {patch_key}")

    return artifacts_dir
```

**Caching**: Artifacts stored in `/shared/pov_patrol/{project_id}/{patch_key}/` to avoid re-downloading.

## POV-Patch Comparison

### Core Comparison Logic ([Lines 69-119](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pov_patch_check.py#L69-L119))

```python
def compare_pov_to_patch(oss_fuzz_project: OSSFuzzProject,
                         pov_report_id: str,
                         patch_key: str,
                         harness_name: str,
                         sanitizer: str,
                         crashing_input: Path):
    """
    Compare a PoV report to a patch.
    Whether the PoV report is mitigated or not is determined by the patch and added to the analysis graph.
    """
    try:
        start_time = time.time()
        run_pov_result: RunPoVResult = oss_fuzz_project.run_pov(
            harness=harness_name,
            data_file=crashing_input,
            sanitizer=sanitizer,
            timeout=110,  # 110-second timeout per POV run
            losan=False,
        )
        logger.info("Time taken to run PoV: %s seconds", time.time() - start_time)
    except Exception as e:
        logger.error("Error running PoV %s for patch %s: %s", pov_report_id, patch_key, e)
        return None  # Retry

    has_crash = run_pov_result.pov is not None and run_pov_result.pov.crash_report is not None

    if has_crash:
        logger.info("PoV %s is not mitigated for patch %s", pov_report_id, patch_key)
        return False  # Patch did NOT fix the vulnerability
    else:
        logger.info("PoV %s is mitigated for patch %s", pov_report_id, patch_key)
        return True  # Patch fixed the vulnerability
```

**Decision Logic**:
- **has_crash = True**: Patch does NOT mitigate → `non_mitigated_povs` relationship
- **has_crash = False**: Patch mitigates → `mitigated_povs` relationship

## Parallel Processing (Patch Mode)

### Worker Pool ([Lines 308-355](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pov_patch_check.py#L308-L355))

```python
max_workers = 3
logger.info("Processing %d relevant PoVs with %d workers", len(available_povs), max_workers)

with tempfile.TemporaryDirectory() as harness_input_dir:
    task_args = []
    for pov in available_povs:
        if patch_node.mitigated_povs.is_connected(pov) or patch_node.non_mitigated_povs.is_connected(pov):
            continue  # Skip already tested POVs

        harness_input = pov.harness_inputs.single()
        crashing_input = Path(harness_input_dir) / str(pov.key)
        crashing_input.write_bytes(bytes.fromhex(str(harness_input.content_hex)))

        args = (oss_fuzz_project, pov.key, patch_node.patch_key, crashing_input,
                pov.content.get('sanitizer'), pov.content.get('cp_harness_name'))
        task_args.append(args)

    with Pool(processes=max_workers) as pool:
        result_iter = pool.imap_unordered(process_pov_report_wrapper, task_args)

        with alive_bar(len(available_povs), title='Comparing patch to PoVs (multiprocess)', bar='fish') as bar:
            for result in result_iter:
                pov_key, patch_key, was_mitigated = result
                total_success += 1 if was_mitigated else 0
                total_errors += 1 if was_mitigated is False else 0
                total_unknown += 1 if was_mitigated is None else 0

                if was_mitigated is None:
                    continue  # Skip failed comparisons

                pov = analysis_graph_patches.PoVReportNode.nodes.get_or_none(key=pov_key)
                if was_mitigated:
                    patch_node.mitigated_povs.connect(pov)
                else:
                    patch_node.non_mitigated_povs.connect(pov)

                bar()
```

**Parallelism**: 3 worker processes test POVs concurrently against the same patch.

### Worker Function ([Lines 221-269](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pov_patch_check.py#L221-L269))

```python
def process_pov_report(oss_fuzz_project: OSSFuzzProject, pov_report_id: str,
                       patch_key: str, crashing_input: Path,
                       sanitizer: str, harness_name: str) -> tuple[str, str, bool]:
    """
    Process a single PoV report against a patch with a 120-second timeout.
    This function is designed to be run in parallel.
    """

    # Set up signal-based timeout
    def timeout_handler(signum, frame):
        raise TimeoutError(f"Task timeout for PoV {pov_report_id}")

    was_mitigated = None
    with tempfile.TemporaryDirectory(dir=SHARED_ARTIFACTS_DIR) as tmp_dir:
        shutil.copytree(oss_fuzz_project.project_path, tmp_dir, dirs_exist_ok=True)
        oss_fuzz_project = OSSFuzzProject(
            project_id=oss_fuzz_project.project_id,
            oss_fuzz_project_path=Path(tmp_dir),
            use_task_service=True
        )

        for _ in range(3):  # 3 retries
            try:
                signal.signal(signal.SIGALRM, timeout_handler)
                signal.alarm(120)  # 120-second timeout

                try:
                    was_mitigated = compare_pov_to_patch(
                        oss_fuzz_project, pov_report_id, patch_key,
                        harness_name, sanitizer, crashing_input
                    )
                finally:
                    signal.alarm(0)  # Disable alarm

            except TimeoutError:
                logger.warning("Task timeout of 120 seconds reached for PoV %s", pov_report_id)
            except Exception as e:
                logger.error("Error processing PoV %s: %s", pov_report_id, e)
            finally:
                signal.alarm(0)

            if was_mitigated is not None:
                break
            logger.info("Retrying PoV %s for patch %s", pov_report_id, patch_key)

    return (pov_report_id, patch_key, was_mitigated)
```

**Timeout**: Each POV-patch comparison has 120-second timeout enforced by `signal.SIGALRM`.

## Analysis Graph Integration

### Graph Relationships ([Lines 200-206](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pov_patch_check.py#L200-L206))

```python
if was_mitigated:
    if not patch.mitigated_povs.is_connected(pov_report_node):
        patch.mitigated_povs.connect(pov_report_node)
else:
    if not patch.non_mitigated_povs.is_connected(pov_report_node):
        patch.non_mitigated_povs.connect(pov_report_node)
patch.save()
```

**Neo4j Relationships**:
- `GeneratedPatch` ← `mitigated_povs` → `PoVReportNode`: Patch fixes this POV
- `GeneratedPatch` ← `non_mitigated_povs` → `PoVReportNode`: Patch does NOT fix this POV

### Completion Tracking

**POV Mode** ([Lines 213-214](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pov_patch_check.py#L213-L214)):
```python
pov_report_node.finished_pov_patrol = True
pov_report_node.save()
```

**Patch Mode** ([Lines 353-354](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pov_patch_check.py#L353-L354)):
```python
patch_node.finished_patch_patrol = True
patch_node.save()
```

## Pipeline Configuration

### POV Mode Task ([Lines 14-94](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pipeline.yaml#L14-L94))

```yaml
pov_patrol:
  priority: 1000000
  job_quota:
    cpu: 1
    mem: "4Gi"
  max_concurrent_jobs: 40
  priority_function: "harness_queue"  # Prioritize by harness backlog

  links:
    pov_report_id:
      repo: dedup_pov_reports
      kind: InputId
    pov_report_meta:
      repo: dedup_pov_report_representative_metadatas
      kind: InputMetadata
    crashing_input_path:
      repo: dedup_pov_report_representative_crashing_inputs
      kind: InputFilepath
```

### Patch Mode Task ([Lines 95-170](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/pov-patrol/pipeline.yaml#L95-L170))

```yaml
patch_patrol:
  priority: 1000000
  job_quota:
    cpu: 4      # More CPU for parallel POV testing
    mem: "8Gi"  # More memory for 3 workers
  max_concurrent_jobs: 35
  priority_function: "harness_queue"

  links:
    patch_id:
      repo: patch_metadatas
      kind: InputId
    patch_metadata:
      repo: patch_metadatas
      kind: InputMetadata
```

**Resource Allocation**:
- **POV mode**: 1 CPU, 4GB RAM (serial patch testing)
- **Patch mode**: 4 CPUs, 8GB RAM (3-worker parallel POV testing)

## Performance Characteristics

- **Timeout**: 120 seconds per POV-patch comparison
- **Retries**: 3 attempts per comparison
- **Parallelism** (Patch mode): 3 workers
- **Max concurrent jobs**: 40 (POV mode), 35 (Patch mode)
- **Caching**: Patch artifacts cached in `/shared/pov_patrol/`
- **Priority**: `harness_queue` - prioritizes based on backlog

## Related Components

- **[POVGuy](./povguy.md)**: Generates validated POVs for testing
- **[Patch Generation](../../patch-generation/)**: Generates patches to test
- **[Analysis Graph](../../infrastructure/analysis-graph.md)**: Stores patch-POV relationships
- **[PDT](../../infrastructure/pydatatask.md)**: Task orchestration framework
