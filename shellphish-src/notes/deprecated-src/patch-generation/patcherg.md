# PatcherG (Governor)

PatcherG is the **orchestrator for the entire patch generation system**. It continuously monitors the Analysis Graph, analyzes POV clusters, scores patches, decides when to submit, and generates patch/refine/bypass requests for PatcherQ.

## Purpose

- Cluster POVs by root cause (buckets)
- Analyze patches in each cluster
- Score patches with Bayesian likelihood
- Strategic submission timing
- Generate patch/refine/bypass requests
- Endgame submission strategy
- Track submitted patches

## Implementation

**Main File**: [`__main__.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/patcherg/__main__.py)

**Runner**: [`run_patcherg.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/scripts/run_patcherg.sh)

## Core Loop ([Lines 934-1154](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/patcherg/__main__.py#L934-L1154))

```python
def run(project_id, patch_request_meta_path, patch_bypass_requests,
        patch_submission_edict_path, crash_submission_edict_path, task_type):

    adjust_task_type_globals(task_type)  # full or delta mode
    bucket_analysis = {}

    while True:
        time.sleep(0.1)

        # 1. Find clusters (groups of related POVs)
        clusters = find_clusters(project_id=project_id)

        # 2. Generate bucket keys for each cluster
        for cluster in clusters:
            bucket_key = hashlib.md5("".join(
                sorted([dedup.identifier for dedup in cluster.organizer_dedup_info_nodes])
            ).encode()).hexdigest()
            cluster_map[bucket_key] = cluster

        # 3. Update buckets in Analysis Graph
        for bucket in cluster_bucket_ids:
            update_or_create_bucket(project_id, bucket, cluster_map)
            process_bucket(project_id, bucket, cluster_map,
                          patch_request_meta_path, bucket_analysis, patch_bypass_requests)

        # 4. Check for functionality failures
        for patch in GeneratedPatch.nodes.filter(pdt_project_id=project_id).all():
            if patch.fail_functionality:
                # Issue refine request with failed_functionality=True
                write_patch_request('refine', poi_report_id=poi_report_id,
                                   patch_id=patch.patch_key, failed_functionality=True)

        # 5. Analyze clusters and select patches to submit
        clusters_and_analysis_pairs = [
            (cluster, analyze_cluster(i, cluster))
            for i, cluster in enumerate(clusters)
        ]

        # 6. Select patches and crashing inputs to submit
        patches_to_submit = []
        for patch, is_imperfect, cluster in select_patches_to_submit(clusters_and_analysis_pairs):
            patches_to_submit.append(patch)

        harness_inputs_to_submit = []
        for harness_input in select_harness_inputs_to_submit(clusters_and_analysis_pairs):
            harness_inputs_to_submit.append(harness_input)

        # 7. Write submission edicts
        for patch in patches_to_submit:
            write_patch_submission_edict(patch, patch_submission_edict_path)
        for harness_input in harness_inputs_to_submit:
            write_crash_submission_edict(harness_input, crash_submission_edict_path)

        sleep(30)  # 30-second poll interval
```

## Cluster Analysis ([Lines 340-504](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/patcherg/__main__.py#L340-L504))

```python
def analyze_cluster(i, cluster: Cluster):
    newest_dedup_node = max(cluster.organizer_dedup_info_nodes, key=lambda dedup: dedup.first_discovered)
    oldest_pov = min(cluster.pov_report_nodes, key=lambda pov: pov.first_discovered)

    perfect_patches = []
    most_recent_best_patch = None
    most_recent_best_mitigated = 0
    oldest_best_patch = None
    already_submitted_patches = []

    # Verify patch metadata is valid
    for patch in cluster.generated_patches:
        patch_has_valid_metadata = verify_patch_metadata_is_valid(patch.patch_key)
        if not patch_has_valid_metadata:
            continue  # Skip patches with invalid metadata

        # Track newest/oldest patches
        if newest_patch is None or patch.time_created > newest_patch.time_created:
            newest_patch = patch
        if oldest_patch is None or patch.time_created < oldest_patch.time_created:
            oldest_patch = patch

        # Count mitigated/unmitigated POVs
        mitigated_in_cluster = patch.mitigated_povs.filter(
            key__in=[pov.key for pov in cluster.pov_report_nodes]
        ).all()
        num_mitigated = len(mitigated_in_cluster)
        num_povs_in_cluster = len(cluster.pov_report_nodes)

        # Track already submitted patches
        if patch.submitted_time or patch.imperfect_submission_in_endgame:
            already_submitted_patches.append(patch)

        # Perfect patch: mitigates all POVs
        if num_mitigated == num_povs_in_cluster:
            perfect_patches.append(patch)

        # Track best patch (most mitigated)
        if num_mitigated > most_recent_best_mitigated:
            oldest_best_patch = patch
            most_recent_best_mitigated = num_mitigated
            most_recent_best_patch = patch

    # Secondary perfection condition: oldest_best_patch has zero unmitigated POVs
    if oldest_best_patch:
        oldest_best_patch_num_unmitigated_in_cluster = len(
            oldest_best_patch.non_mitigated_povs.filter(
                key__in=[pov.key for pov in cluster.pov_report_nodes]
            )
        )
        if oldest_best_patch_num_unmitigated_in_cluster == 0 and \
           (len(oldest_best_patch.non_mitigated_povs) > 0 or oldest_best_patch.finished_patch_patrol):
            perfect_patches.append(oldest_best_patch)

    return ClusterAnalysis(
        perfect_patches=perfect_patches,
        most_recent_best_patch=most_recent_best_patch,
        oldest_best_patch=oldest_best_patch,
        already_submitted_patches=already_submitted_patches,
        ...
    )
```

**Perfection Criteria**:
1. **Primary**: `num_mitigated == num_povs_in_cluster`
2. **Secondary**: `num_unmitigated_in_cluster == 0` and patch has been tested by POV-Patrol

## Patch Scoring ([Lines 95-133](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/patcherg/__main__.py#L95-L133))

```python
def score_patch(patch: GeneratedPatch, cluster: Cluster) -> float:
    """
    Higher is better patch. The range is [0,1]
    """
    mitigated_in_cluster = len(patch.mitigated_povs.filter(
        key__in=[pov.key for pov in cluster.pov_report_nodes]
    ).all())
    unmitigated_in_cluster = len(patch.non_mitigated_povs.filter(
        key__in=[pov.key for pov in cluster.pov_report_nodes]
    ).all())

    total_povs = mitigated_in_cluster + unmitigated_in_cluster
    return bayesian_likelihood_score(mitigated_in_cluster, total_povs)

def bayesian_likelihood_score(k: int, n: int, alpha: float = 1.0, beta: float = 1.0) -> float:
    """
    Bayesian likelihood-style score for a patch that mitigates `k`
    out of `n` vulnerabilities.

    Uses a Beta(alpha, beta) prior (Jeffreys / Laplace smoothing when
    alpha = beta = 1).  The returned score is the posterior mean of the
    mitigation probability:

        E[p | data] = (k + alpha) / (n + alpha + beta)

    Properties (with alpha = beta = 1):
        • 3/3 (0.800)  > 2/3 (0.600)      [perfect small sample beats imperfect]
        • 49/50 (0.962) > 3/3 (0.800)     [high testing volume beats small sample]
        • 50/50 (0.981) > 3/3 (0.800)     [perfect large sample beats perfect small]
        • 50/50 (0.981) > 49/50 (0.962)   [perfect beats near-perfect]
    """
    if n <= 0:
        return 0
    return (k + alpha) / (n + alpha + beta)
```

**Bayesian Scoring**: Favors patches with:
1. Higher mitigation rate (`k/n`)
2. More testing (`n` larger)
3. Perfect patches (`k == n`)

## Strategic Submission ([Lines 506-627](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/patcherg/__main__.py#L506-L627))

```python
def select_patches_to_submit(cluster_and_analysis_pairs) -> Iterator[tuple[GeneratedPatch, bool, Cluster]]:
    for i, (cluster, analysis) in enumerate(cluster_and_analysis_pairs):
        is_imperfect = False
        time_to_deadline = get_time_to_deadline()
        in_endgame = time_to_deadline < timedelta(minutes=NON_PERFECT_PATCH_SUBMISSION_TIMEOUT_MINUTES)  # 45 min

        # Calculate timeout based on cluster count
        if analysis.already_submitted_patches and len(analysis.already_submitted_patches) > TOO_MANY_PATCHES_PER_BUCKETS:
            good_patch_submission_timeout_minutes = GOOD_PATCH_SUBMISSION_TIMEOUT_MINUTES * 2
        else:
            good_patch_submission_timeout_minutes = GOOD_PATCH_SUBMISSION_TIMEOUT_MINUTES

        # Submit perfect patch if old enough
        if analysis.perfect_patches and analysis.oldest_best_patch:
            if is_patch_older_than_minutes(analysis.oldest_best_patch, good_patch_submission_timeout_minutes):
                # Prefer non-PatcherY patches if available
                if analysis.oldest_best_patch.patcher_name == "PatcherY":
                    if all([patch.patcher_name == "PatcherY" for patch in analysis.perfect_patches]):
                        if not in_endgame:
                            continue  # Wait for non-PatcherY patch
                    else:
                        # Submit best non-PatcherY perfect patch
                        oldest_best_patch_no_patchery = analysis.oldest_best_patch_no_py
                        if oldest_best_patch_no_patchery and is_patch_older_than_minutes(oldest_best_patch_no_patchery, good_patch_submission_timeout_minutes):
                            yield oldest_best_patch_no_patchery, is_imperfect, cluster
                        continue

                yield analysis.oldest_best_patch, is_imperfect, cluster
            elif in_endgame:
                # Endgame: submit even if not old enough
                is_imperfect = True
                analysis.oldest_best_patch.imperfect_submission_in_endgame = True
                yield analysis.oldest_best_patch, is_imperfect, cluster

        # Endgame: submit best imperfect patch
        elif analysis.most_recent_best_patch and analysis.most_recent_best_mitigated > 0:
            is_imperfect = True

            if in_endgame and len(analysis.already_submitted_patches) == 0:
                # Prefer non-PatcherY patches
                if analysis.oldest_best_patch.patcher_name == "PatcherY":
                    if analysis.oldest_best_patch_no_py and \
                       len(analysis.oldest_best_patch_no_py.mitigated_povs) == analysis.most_recent_best_mitigated:
                        analysis.oldest_best_patch_no_py.imperfect_submission_in_endgame = True
                        yield analysis.oldest_best_patch_no_py, is_imperfect, cluster
                        continue

                analysis.oldest_best_patch.imperfect_submission_in_endgame = True
                yield analysis.oldest_best_patch, is_imperfect, cluster
```

**Submission Strategy**:
1. **Perfect patches**: Wait for timeout, then submit oldest perfect patch
2. **PatcherY bias**: Prefer non-PatcherY patches when available
3. **Endgame**: Submit imperfect patches 45 minutes before deadline
4. **Max imperfect**: Limit to 3 imperfect patches per project (full mode)

## Timeout Configuration ([Lines 34-93](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/patcherg/__main__.py#L34-L93))

```python
# Full mode (12 hours)
GOOD_PATCH_SUBMISSION_TIMEOUT_MINS_FULL = 60
BUCKET_SLOW_DOWN_AMT_FULL = 12
MAX_IMPERFECT_PATCHES_TOTAL_FULL = 3

# Delta mode (6 hours)
GOOD_PATCH_SUBMISSION_TIMEOUT_MINS_DELTA = 30
BUCKET_SLOW_DOWN_AMT_DELTA = 6
MAX_IMPERFECT_PATCHES_TOTAL_DELTA = 2

def update_good_patch_submission_timeout(cluster_cnt: int) -> int:
    """
    * cluster_cnt < BUCKET_SLOW_DOWN   → baseline timeout
    * cluster_cnt ≥ BUCKET_SLOW_DOWN   → baseline × (1.5 + α · log₂(1 + extra))
      with "extra" = how many clusters we are past the threshold.
    """
    if cluster_cnt < BUCKET_SLOW_DOWN_AMT:
        return GOOD_PATCH_SUBMISSION_TIMEOUT_MINS_BASE

    extra = cluster_cnt - BUCKET_SLOW_DOWN_AMT
    a = 0.20
    growth = 1.5 + a * math.log2(1 + extra)
    return int(GOOD_PATCH_SUBMISSION_TIMEOUT_MINS_BASE * growth)
```

**Adaptive Timeout**: Increases logarithmically with cluster count to "cook" patches longer when many clusters exist.

## Request Generation

### Patch Request ([Lines 708-722](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/patcherg/__main__.py#L708-L722))

```python
def write_patch_request(request_type: str, poi_report_id: str, bucket_id: str | None,
                        patch_request_meta: Path, patch_id: str | None = None,
                        patcher_name: str | None = None, failed_functionality: bool = False):
    request = PatchRequestMeta(
        request_type=request_type,  # "patch" or "refine"
        poi_report_id=poi_report_id,
        patch_id=patch_id,
        patcher_name=patcher_name,
        bucket_id=bucket_id,
        failed_functionality=failed_functionality,
    )
    with open(patch_request_meta, 'w') as f:
        yaml.safe_dump(request.model_dump(), f)
```

**Request Types**:
- **patch**: Initial patch request for new POV
- **refine**: Refine existing patch to fix bypassing POV

### Bypass Request ([Lines 724-737](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/patcherg/__main__.py#L724-L737))

```python
def write_bypass_request(project_id: str, harness_id: str, patch_id: str,
                         mitigated_poi_report_id: str, patcher_name: str,
                         build_request_id: str, patch_bypass_request_meta: Path,
                         patch_description: str | None = None,
                         sanitizer_name: str | None = None):
    request = PatchBypassRequestMeta(
        project_id=project_id, harness_id=harness_id, patch_id=patch_id,
        mitigated_poi_report_id=mitigated_poi_report_id,
        patcher_name=patcher_name, build_request_id=build_request_id,
        patch_description=patch_description, sanitizer_name=sanitizer_name
    )
    with open(patch_bypass_request_meta, 'w') as f:
        yaml.safe_dump(request.model_dump(), f)
```

**Bypass Request**: Tests perfect patch against other projects' POVs to find bypasses for offensive play.

## Bucket Management ([Lines 739-774](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/patcherg/__main__.py#L739-L774))

```python
def update_or_create_bucket(project_id: str, bucket_key: str, cluster_map: dict[str, Cluster]):
    cluster = cluster_map.get(bucket_key)

    max_povs = 0
    all_relevant_patches = []
    contains_povs = [pov.key for pov in cluster.pov_report_nodes]
    best_patch_id = None
    oldest_patch_time = None
    patch_mitigated_povs = generate_patch_povs_map(cluster)

    # Find best patch (mitigates most POVs, oldest if tied)
    for patch in cluster.generated_patches:
        mitigated_in_cluster = patch_mitigated_povs[patch.patch_key]
        if mitigated_in_cluster > max_povs:
            max_povs = mitigated_in_cluster
        all_relevant_patches.append(patch.patch_key)

    for patch in cluster.generated_patches:
        if patch_mitigated_povs[patch.patch_key] == max_povs:
            if oldest_patch_time is None or patch.time_created < oldest_patch_time:
                best_patch_id = patch.patch_key

    BucketNode.upload_bucket(project_id, bucket_key, datetime.now(),
                            best_patch_id, contains_povs, all_relevant_patches)
```

**BucketNode**: Neo4j node tracking cluster state, best patch, and contained POVs.

## Harness Input Submission ([Lines 629-692](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/patcherg/patcherg/__main__.py#L629-L692))

```python
def select_harness_inputs_to_submit(clusters_and_analysis_pairs) -> Iterator[HarnessInputNode]:
    for i, (cluster, cluster_analysis) in enumerate(clusters_and_analysis_pairs):
        # Always yield oldest harness input for oldest POV
        oldest_pov = cluster_analysis.oldest_pov
        oldest_harness_input = min(oldest_pov.harness_inputs, key=lambda h: h.first_discovered_timestamp)
        yield oldest_harness_input

        # Submit harness inputs from first 15 minutes of bucket creation
        oldest_pov_discovered_ts = normalize_time(cluster_analysis.oldest_pov.first_discovered).timestamp()
        for pov in cluster.pov_report_nodes:
            oldest_harness_input = min(pov.harness_inputs, key=lambda h: h.first_discovered_timestamp)
            now = get_current_normalized_time().timestamp()
            current_age_difference = now - oldest_pov_discovered_ts

            if current_age_difference < NEW_BUCKET_HARNESS_INPUT_SUBMISSION_CUTOFF_MINUTES * 60:  # 15 min
                yield oldest_harness_input

            # Submit if multiple perfect patches were submitted (offensive play)
            elif len(cluster_analysis.already_submitted_perfect_patches) > 1:
                harness_input_discovered_ts = normalize_time(oldest_harness_input.first_discovered_timestamp).timestamp()
                newest_submitted_patch = max(cluster_analysis.already_submitted_perfect_patches,
                                            key=lambda p: normalize_time(p.submitted_time).timestamp())
                newest_submitted_patch_created_ts = normalize_time(newest_submitted_patch.time_created).timestamp()

                if harness_input_discovered_ts < newest_submitted_patch_created_ts:
                    yield oldest_harness_input  # Break other teams' patches
```

**Submission Strategy**:
1. Always submit oldest harness input
2. Submit inputs from first 15 minutes of bucket
3. Offensive play: Submit inputs to break other teams' patches if we have multiple perfect patches

## Performance Characteristics

- **Polling interval**: 30 seconds
- **Priority**: Critical node pool (high-priority)
- **Resources**: 1 CPU, 4GB RAM
- **Timeout adjustment**: Logarithmic growth (1.5x base + 0.20 * log2(extra clusters))
- **Max imperfect submissions**: 3 (full mode), 2 (delta mode)
- **Endgame threshold**: 45 minutes before deadline

## Related Components

- **[PatcherQ](./patcherq.md)**: Receives patch/refine/bypass requests
- **[POV-Patrol](../bug-finding/pov-generation/pov-patrol.md)**: Tests patches against POVs
- **[Analysis Graph](../infrastructure/analysis-graph.md)**: Stores clusters and patch state
- **[Submission](../infrastructure/submission.md)**: Submits patches and crashes
