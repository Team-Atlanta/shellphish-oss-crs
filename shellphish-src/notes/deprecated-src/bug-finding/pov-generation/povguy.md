# POVGuy

POVGuy **validates and deduplicates crashes** by running them multiple times to ensure consistency. It supports delta mode to reject crashes that also occur in the base version, and uploads validated POVs to the Analysis Graph.

## Purpose

- Multi-run validation for crash consistency
- Sanitizer consistency checking
- Delta mode: test against base version
- Deduplication by crash signature
- LOSAN support for Java
- Analysis graph integration

## Validation Workflow

### 1. Multi-Run Validation ([Lines 120-173](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/povguy/povguy.py#L120-L173))

```python
# Run POV 5 times to check consistency
consistently_triggered_sanitizers = None
triggered_sanitizer_history = []

for idx in range(5):  # retry_count
    run_pov_result = cp.run_pov(
        harness_name,
        data_file=pov_path,
        timeout=60,
        function_resolver=function_resolver,
        sanitizer=crash_metadata.sanitizer
    )

    pov = run_pov_result.pov

    if idx == 0:
        consistently_triggered_sanitizers = set(pov.triggered_sanitizers)
    else:
        # Intersection: only sanitizers that trigger every time
        consistently_triggered_sanitizers &= set(pov.triggered_sanitizers)

    # Stop early if no consistent sanitizers
    if len(consistently_triggered_sanitizers) == 0:
        break

    triggered_sanitizer_history.append(list(sorted(set(pov.triggered_sanitizers))))
```

**Consistency Check**: Only accept POVs where the same sanitizers trigger on every run.

### 2. Significance Check ([Lines 213-219](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/povguy/povguy.py#L213-L219))

```python
# Check if crash is significant
if all(k == SignificanceEnum.NoSignificantCrashRecognized for k in significances_history):
    if not is_losan:  # Java LOSAN crashes may have low significance
        log.error("No significant crash recognized in any run")
        exit(0)  # Reject POV
```

**Significance**: Crashes must be recognized as significant (not just timeouts or benign exits).

### 3. Stack Trace Validation ([Lines 221-227](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/povguy/povguy.py#L221-L227))

```python
if not seen_stack_traces or not [stack_trace for stack_trace in seen_stack_traces.values() if stack_trace]:
    log.error("No useful stack traces found: %s", seen_stack_traces)
    exit(0)  # Reject POV
```

**Stack Traces**: Must have at least one valid stack trace for patch generation.

## Delta Mode

**Purpose**: Reject crashes that also occur in the base (unpatched) version.

**Workflow** ([Lines 246-323](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/povguy/povguy.py#L246-L323)):

```python
if base_project:
    # Copy base project to tmp dir
    base_target_tmp_dir = tempfile.mkdtemp(dir='/shared')
    subprocess.call(['rsync', '-ra', '--delete',
                     str(base_project) + '/',
                     str(base_target_tmp_dir) + '/'])

    cp_base = OSSFuzzProject(Path(base_target_tmp_dir))
    cp_base.build_runner_image()

    # Run POV on base version (3 times)
    for base_idx in range(retry_count // 2 + 1):  # 3 runs
        base_run_pov_result = cp_base.run_pov(
            harness_name,
            data_file=pov_path,
            timeout=60
        )

        base_pov = base_run_pov_result.pov

        if base_pov.crash_report:
            # Crash occurs on base version too
            logger.critical("POV crashes in the base project")
            exit(0)  # Reject POV (not a regression)
```

**Delta Mode Logic**:
- If crash occurs on **both** patch and base: **Reject** (pre-existing bug)
- If crash occurs **only** on patch: **Accept** (regression)

## Deduplication

### 1. Crash Report Hashing ([Lines 338-346](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/povguy/povguy.py#L338-L346))

```python
# Remove variable parts for deduplication
run_pov_result.pov.crash_report = None
run_pov_result.pov.extra_context = None

report = PoVReport(
    inconsistent_sanitizers=inconsistent_sanitizers,
    consistent_sanitizers=consistent_sanitizers,
    **crash_metadata.model_dump(),
    **run_pov_result.pov.model_dump(),
)

# Hash crash report for deduplication
crash_report = yaml.dump(json.loads(report.model_dump_json())).encode()
crash_report_md5 = hashlib.md5(crash_report).hexdigest()
```

### 2. Representative Selection
- Crashes with same `crash_report_md5` are grouped
- First crash in group becomes representative
- Others are discarded

## LOSAN Support

**LOSAN** (Leak-Only Sanitizer): Java-specific sanitizer for Java applications.

**Detection** ([Lines 91-94](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/povguy/povguy.py#L91-L94)):
```python
if cp.project_language.name == "jvm":
    log.info("Running pov with Losan Jazzer instrumentation")
    cp = InstrumentedOssFuzzProject(
        oss_fuzz_project_path=project_dir,
        instrumentation=JazzerInstrumentation()
    )
    extra_env = {"SHELL_SAN": "LOSAN"}
```

**LOSAN Output Routing** ([Lines 373-378](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/povguy/povguy.py#L373-L378)):
```python
if run_pov_result.pov.dedup_crash_report.losan:
    # Dump to LOSAN-specific output directories
    out_dedup_pov_report_path = out_dedup_losan_report_path
    out_dedup_pov_report_representative_metadata_path = out_dedup_losan_report_representative_metadata_path
    out_dedup_pov_report_representative_crash_path = out_dedup_losan_report_representative_crash_path
    out_dedup_pov_report_representative_full_report_path = out_dedup_losan_report_representative_full_report_path
```

## Analysis Graph Upload

**HarnessInputNode** ([Lines 232-241](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/povguy/povguy.py#L232-L241)):
```python
newly_created, analysis_graph_harness_input = HarnessInputNode.create_node(
    harness_info_id=str(crash_metadata.harness_info_id),
    harness_info=crashing_input_metadata,
    content=pov_content,  # Seed bytes
    crashing=run_pov_result.pov.crash_report is not None,
    pdt_id=crash_id,
)
```

**PoVReportNode** ([Lines 355-359](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/povguy/povguy.py#L355-L359)):
```python
newly_created, analysis_graph_pov_report = analysis_graph_crash_reports.PoVReportNode.from_crs_utils_pov_report(
    crash_report_md5,
    report
)
analysis_graph_pov_report.harness_inputs.connect(analysis_graph_harness_input)
```

## Output Files

1. **Per-crash full report**: `out_per_crash_full_pov_report_path`
2. **Dedup POV report**: `out_dedup_pov_report_path` (MD5-hashed)
3. **Representative crash**: `out_dedup_pov_report_representative_crash_path` (seed file)
4. **Representative metadata**: `out_dedup_pov_report_representative_metadata_path`
5. **Representative full report**: `out_dedup_pov_report_representative_full_report_path`

LOSAN variants: Same structure with `losan` prefix.

## Performance Characteristics

- **Validation**: 5 runs per POV (~5-10 minutes)
- **Delta mode**: +3 base runs (~3-6 minutes)
- **Timeout**: 60 seconds per run (configurable)
- **Total time**: ~5-15 minutes per POV

## Related Components

- **[Crash-Tracer](../crash-analysis/crash-tracer.md)**: Provides crash reports
- **[POIGuy](./poiguy.md)**: Generates POI from validated POVs
- **[POV-Patrol](./pov-patrol.md)**: Tests patches against POVs
- **[Analysis Graph](../../infrastructure/analysis-graph.md)**: Stores POV nodes
