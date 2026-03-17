# Analysis Graph

The **Analysis Graph** is a Neo4j-based knowledge graph that tracks all analysis results, relationships, and metadata across the entire CRS pipeline. It provides a centralized, queryable store for coverage, crashes, patches, and their complex inter-relationships.

## Purpose

- Track function-level code coverage from fuzzing and dynamic analysis
- Store POV reports with deduplication and crash grouping
- Manage patch generation metadata and verification results
- Maintain relationships between inputs, coverage, crashes, and patches
- Support complex queries for LLM agents (PatcherQ, AIJON, PatcherG)
- Enable concurrent writes from distributed components

## Architecture

```mermaid
graph TD
    A[Coverage-Guy] -->|Upload Coverage| B[Analysis Graph]
    C[POVGuy] -->|Upload POV Reports| B
    D[PatcherQ] -->|Upload Patches| B
    E[SARIFGuy] -->|Upload SARIF Results| B
    B -->|Neo4j Bolt| F[Neo4j Database]
    F -->|Query| G[PatcherG]
    F -->|Query| H[AIJON]
    F -->|Query| I[PatcherQ]

    subgraph "Node Types"
        J[CFGFunction]
        K[HarnessInputNode]
        L[PoVReportNode]
        M[GeneratedPatch]
        N[OrganizerDedupInfoNode]
        O[CoveredFunctionLine]
    end
```

## Core Node Types

### 1. CFGFunction

**Purpose**: Represents a function in the target program's control flow graph.

**Implementation** ([cfg.py:40-79](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/models/cfg.py#L40-L79)):

```python
class CFGFunction(StructuredNode):
    identifier = StringProperty(unique_index=True)
    created_at = DateTimeProperty(default=lambda: datetime.now(pytz.utc))
    function_name = StringProperty()
    function_signature = StringProperty()
    filename = StringProperty()
    filepath = StringProperty()

    start_line = IntegerProperty()
    end_line = IntegerProperty()
    start_col = IntegerProperty()
    end_col = IntegerProperty()
    start_byte = IntegerProperty()
    end_byte = IntegerProperty()
    code = StringProperty()

    first_discovered = IntegerProperty()  # timestamp of first discovery

    # Call graph relationships
    direct_call = RelationshipTo('CFGFunction', 'DIRECTLY_CALLS', model=DynamicRelationProperty)
    may_indirect_call = RelationshipTo('CFGFunction', 'MAYBE_INDIRECT_CALLS', model=DynamicRelationProperty)
    guaranteed_indirect_call = RelationshipTo('CFGFunction', 'GUARANTEED_INDIRECT_CALLS', model=DynamicRelationProperty)

    # Pointer relationships
    takes_pointer_of_function = RelationshipTo('CFGFunction', 'TAKES_POINTER_OF', model=ReferenceProperty)
    takes_pointer_of_global = RelationshipTo('CFGGlobalVariable', 'TAKES_POINTER_OF', model=ReferenceProperty)

    # Coverage relationships
    covered_lines = RelationshipTo('CoveredFunctionLine', 'CONTAINS_LINE')
    covering_harness_inputs = RelationshipFrom('HarnessInputNode', 'COVERS')
    covering_grammars = RelationshipFrom('Grammar', 'COVERS')

    # Vulnerability relationships
    has_cwe_vulnerability = RelationshipTo('CWEVulnerability', 'HAS_CWE_VULNERABILITY', model=CWEVulnerabilityMetadata)
```

**Identifier Format**: `{filename}::{function_name}::{start_line}`

**Usage**: LLM agents query for covered/uncovered functions, call graphs, vulnerability locations.

### 2. HarnessInputNode

**Purpose**: Represents a unique input to a harness (fuzzer seed, POV, grammar-generated).

**Implementation** ([harness_inputs.py:27-43](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/models/harness_inputs.py#L27-L43)):

```python
class HarnessInputNode(HarnessNode):
    identifier = StringProperty(unique_index=True, required=True)
    content_hash = StringProperty(required=True)
    crashing = BooleanProperty(required=True)
    content_hex = StringProperty()
    content_escaped = StringProperty()
    pdt_id = StringProperty()

    first_discovered_timestamp = DateTimeProperty(default=lambda: datetime.now(pytz.utc))
    first_discovered_fuzzer = StringProperty(choices=KNOWN_FUZZER_NAMES_PROPERTY_CHOICES)

    reached_functions = RelationshipTo('CFGFunction', 'REACHES_FUNCTION')
    mutated_from = RelationshipFrom('HarnessInputNode', 'MUTATED_FROM', model=SeedRelationship)

    covered_lines = RelationshipTo('CoveredFunctionLine', 'COVERS')
    covered_functions = RelationshipTo('CFGFunction', 'COVERS')

    bypass_patch = RelationshipTo('GeneratedPatch', 'BYPASS')
```

**Identifier Computation** ([harness_inputs.py:46-49](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/models/harness_inputs.py#L46-L49)):

```python
@staticmethod
def compute_identifier(harness_info_id: str, harness_info: HarnessInfo, content: bytes, crashing: bool) -> str:
    content_hash = hashlib.sha256(content).hexdigest()
    return f'{harness_info_id}:{content_hash}:{crashing}'
```

**Purpose**: Deduplicate inputs across multiple fuzzer instances, track coverage provenance.

### 3. PoVReportNode

**Purpose**: Deduplicated crash report with consistent sanitizer triggers.

**Implementation** ([crashes.py:239-282](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/models/crashes.py#L239-L282)):

```python
class PoVReportNode(ShellphishBaseNode):
    uid = UniqueIdProperty()  # unique identifier for the node
    key = StringProperty(unique_index=True, required=True)
    pdt_project_id = StringProperty(required=True)
    content = JSONProperty()

    first_discovered = DateTimeNeo4jFormatProperty(default=lambda: datetime.now(pytz.utc))
    last_scanned_for_deduplication = DateTimeNeo4jFormatProperty(default=None)
    harness_inputs = RelationshipTo('HarnessInputNode', 'HARNESS_INPUT', model=TimedRelationEdgeModel)
    organizer_dedup_infos = RelationshipTo('OrganizerDedupInfoNode', 'ORGANIZER_DEDUP_INFO')
    finished_pov_patrol = BooleanProperty(default=False)

    submitted_time = DateTimeNeo4jFormatProperty(default=None)
    submission_result_time = DateTimeNeo4jFormatProperty(default=None)
    failed = BooleanProperty()  # whether the pov failed to crash

    @classmethod
    def from_crs_utils_pov_report(cls, pov_report_id: str, pov_report: CRSUtilsPOVReport, failed: bool = False) -> Tuple[bool, 'PoVReportNode']:
        vals = {}
        vals['key'] = pov_report_id
        vals['content'] = json.loads(pov_report.model_dump_json())
        vals['pdt_project_id'] = pov_report.project_id
        vals['failed'] = failed
        newly_created, self = cls.create_node_safely(vals)

        orga_dedup_info = OrganizerDedupInfoNode.from_crs_utils_dedup_info(
            pov_report.organizer_crash_eval.crash_state,
            pov_report.organizer_crash_eval.instrumentation_key,
            pdt_project_id=pov_report.project_id,
        )
        self.organizer_dedup_infos.connect(orga_dedup_info)
        self.save()

        return newly_created, self
```

**Deduplication**: Groups POVs by crash state + instrumentation key via `OrganizerDedupInfoNode`.

### 4. GeneratedPatch

**Purpose**: Stores patch metadata, verification results, and relationships to POVs.

**Implementation** ([crashes.py:284-355](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/models/crashes.py#L284-L355)):

```python
class GeneratedPatch(ShellphishBaseNode):
    uid = UniqueIdProperty()
    patch_key = StringProperty(unique_index=True)
    pdt_project_id = StringProperty(required=True)
    diff = StringProperty()
    time_created = DateTimeNeo4jFormatProperty(default=lambda: datetime.now(tz=timezone.utc))
    submitted_time = DateTimeNeo4jFormatProperty(default=None)
    submission_result_time = DateTimeNeo4jFormatProperty(default=None)
    fail_functionality = BooleanProperty()
    finished_patch_patrol = BooleanProperty(default=False)
    imperfect_submission_in_endgame = BooleanProperty(default=False)

    extra_metadata = JSONProperty()

    patcher_name = StringProperty()
    total_cost = FloatProperty()

    pov_report_generated_from = RelationshipTo('PoVReportNode', 'POV_REPORT', model=TimedRelationEdgeModel)
    mitigated_povs = RelationshipTo('PoVReportNode', 'MITIGATED_POV_REPORT', model=TimedRelationEdgeModel)
    non_mitigated_povs = RelationshipTo('PoVReportNode', 'NON_MITIGATED_POV_REPORT', model=TimedRelationEdgeModel)
    refined_from_patch = RelationshipTo('GeneratedPatch', 'REFINED_FROM', model=TimedRelationEdgeModel)
    sarif_report_generated_from = RelationshipTo('SARIFreport', 'SARIF_REPORT_GENERATED_FROM', model=TimedRelationEdgeModel)

    @classmethod
    def upload_patch(cls, pdt_project_id: str, patch_pdt_id: str, diff: str, poi_report_id: str,
                     mitigated_poi_report_ids: List[str], non_mitigated_poi_report_ids: List[str],
                     refined_patch_id: Optional[str], fail_functionality: bool = False,
                     patcher_name: str='unknown', total_cost: float=0.0, **extra_metadata) -> 'GeneratedPatch':
        self = cls.get_or_create_node_reliable({
            'patch_key': patch_pdt_id,
            'pdt_project_id': pdt_project_id,
            'diff': diff,
            'fail_functionality': fail_functionality,
            'extra_metadata': json.loads(json.dumps(extra_metadata)),
            'patcher_name': patcher_name,
            'total_cost': total_cost,
        })
        self.time_created = datetime.now(tz=timezone.utc)
        self.pov_report_generated_from.connect(PoVReportNode.get_or_create_node_reliable({'key': poi_report_id, 'pdt_project_id': pdt_project_id}))

        for mitigated_poi_report_id in mitigated_poi_report_ids:
            self.mitigated_povs.connect(PoVReportNode.get_or_create_node_reliable({
                'key': mitigated_poi_report_id,
                'pdt_project_id': pdt_project_id
            }))

        for non_mitigated_poi_report_id in non_mitigated_poi_report_ids:
            non_mitigated_pov_report = PoVReportNode.get_or_create_node_reliable({
                'key': non_mitigated_poi_report_id,
                'pdt_project_id': pdt_project_id
            })
            self.non_mitigated_povs.connect(non_mitigated_pov_report)

        if refined_patch_id:
            refined_patch = GeneratedPatch.get_or_create_node_reliable({
                'patch_key': refined_patch_id,
                'pdt_project_id': pdt_project_id,
            })
            self.refined_from_patch.connect(refined_patch)

        self.save()
        return self
```

**Relationships**:
- `pov_report_generated_from`: Which POV triggered this patch
- `mitigated_povs`: POVs this patch fixes
- `non_mitigated_povs`: POVs this patch doesn't fix (regression tracking)
- `refined_from_patch`: Parent patch if this is a refinement

### 5. OrganizerDedupInfoNode

**Purpose**: Deduplication metadata based on organizer-provided crash state.

**Implementation** ([crashes.py:166-222](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/models/crashes.py#L166-L222)):

```python
class OrganizerDedupInfoNode(ShellphishBaseNode):
    identifier = StringProperty(unique_index=True, required=True)
    identifier_string = StringProperty(required=True)
    pdt_project_id = StringProperty(required=True)
    crash_state = StringProperty(required=True)
    instrumentation_key = StringProperty()

    first_discovered = DateTimeNeo4jFormatProperty(default=lambda: datetime.now(pytz.utc))
    last_scanned_for_deduplication = DateTimeNeo4jFormatProperty(default=None)

    tokens = RelationshipTo('DedupTokenNode', 'DEDUP_TOKEN')
    generated_patches = RelationshipFrom('GeneratedPatch', 'GENERATED_PATCH_FOR', model=TimedRelationEdgeModel)
    pov_reports = RelationshipFrom('PoVReportNode', 'ORGANIZER_DEDUP_INFO', model=TimedRelationEdgeModel)

    organizer_equivalent_nodes = Relationship('OrganizerDedupInfoNode', 'ORGANIZER_EQUIVALENT_DEDUP_INFO', model=TimedRelationEdgeModel)

    def maybe_recompute_duplicates(self, force_update=False):
        """
        Recompute the duplicates of this node in the analysis graph.
        This is used to ensure that the duplicates are up-to-date.
        """
        from analysis_graph.api.dedup import connect_new_dedup_info_node_in_analysis_graph
        time_since_last_duplicate_recomputation = self.get_current_neo4j_time() - self.last_scanned_for_deduplication if self.last_scanned_for_deduplication else None
        if not force_update and (time_since_last_duplicate_recomputation is None or time_since_last_duplicate_recomputation.total_seconds() <= 15 * 60):
            return

        # 15 minutes have passed since the last recomputation, so we recompute the duplicates to make sure the info is up-to-date
        if self.instrumentation_key is None:
            connect_new_dedup_info_node_in_analysis_graph(newly_added_dedup_info_node=self)
        self.last_scanned_for_deduplication = OrganizerDedupInfoNode.get_current_neo4j_time()
        self.save()

    @classmethod
    def from_crs_utils_dedup_info(cls, crash_state, instrumentation_key, pdt_project_id: PDT_ID) -> 'OrganizerDedupInfoNode':
        identifier_string = f'{pdt_project_id}-{crash_state}-{instrumentation_key or ""}'
        identifier = hashlib.sha256(identifier_string.encode()).hexdigest()
        value = {
            'pdt_project_id': pdt_project_id,
            'identifier': identifier,
            'identifier_string': identifier_string,
            'crash_state': crash_state,
        }
        if instrumentation_key is not None:
            value['instrumentation_key'] = instrumentation_key

        is_new, self = cls.create_node_safely(value)
        if is_new:
            self.save()

        self.maybe_recompute_duplicates(force_update=is_new)
        return self
```

**Deduplication Strategy**: Crashes with same `crash_state` + `instrumentation_key` are grouped together.

**Periodic Refresh**: Every 15 minutes, recompute duplicates to catch newly added POVs.

### 6. BucketNode

**Purpose**: Groups related POVs and patches for cluster-based patch generation.

**Implementation** ([crashes.py:385-425](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/models/crashes.py#L385-L425)):

```python
class BucketNode(ShellphishBaseNode):
    pdt_project_id = StringProperty(required=True)
    bucket_key = StringProperty(unique_index=True)
    last_updated_time = DateTimeNeo4jFormatProperty(default=lambda: datetime.now(pytz.utc))
    best_patch_key = StringProperty(default=None)

    contain_povs = RelationshipTo('PoVReportNode', 'CONTAIN_POV_REPORT')
    contain_patches = RelationshipTo('GeneratedPatch', 'CONTAIN_PATCH')
```

**Usage**: PatcherG creates buckets of related POVs, generates patches for each bucket, tracks best patch per bucket.

## Coverage Upload

**Registration Flow** ([dynamic_coverage.py:39-135](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/api/dynamic_coverage.py#L39-L135)):

```python
def register_harness_input_function_coverage(harness_input_id: str, harness_info_id: str, harness_info: HarnessInfo, input: bytes, crashing: bool, cov: FunctionCoverageMap):

    covered_lines = {(k, l.line_number) for k in cov.keys() for l in cov[k] if l.count_covered}
    covered_func_keys = {x[0] for x in covered_lines}

    # Compute unique identifier
    harness_input_identifier = HarnessInputNode.compute_identifier(
        harness_info_id=harness_info_id,
        harness_info=harness_info,
        content=input,
        crashing=crashing
    )

    # Create or get harness input node
    this_thread_created_this_node = False
    harness_input_node = None
    try:
        this_thread_created_this_node, harness_input_node = HarnessInputNode.create_node(
            harness_info_id=harness_info_id,
            harness_info=harness_info,
            content=input,
            crashing=crashing,
        )
    except Exception as e:
        harness_input_node = None

    # If another thread created it, return early
    if not this_thread_created_this_node:
        return harness_input_node

    # Create CFGFunction nodes and relationships
    cfg_function = None
    for k in covered_func_keys:
        try:
            with db.write_transaction as tx:
                cfg_function = CFGFunction.nodes.get_or_none(identifier=k)
                if cfg_function is None:
                    # Create it!
                    try:
                        cfg_function = CFGFunction.create(
                            dict(identifier=k),
                            relationship=[(harness_input_node.covered_functions, "COVERS")]
                        )[0]
                        cfg_function.save()
                    except Exception as e:
                        # Race condition: another thread created it
                        cfg_function = None
        except Exception as e:
            cfg_function = None

        try:
            with db.write_transaction as tx:
                if cfg_function is None:
                    cfg_function = CFGFunction.nodes.get_or_none(identifier=k)

                # Create relationship with raw query (neomodel creates cartesian products otherwise)
                query = f"""
                MATCH (hi:HarnessInputNode)
                WHERE hi.identifier = "{harness_input_node.identifier}"
                MATCH (cf:CFGFunction)
                WHERE cf.identifier = "{k}"
                MERGE (hi)-[r:COVERS]->(cf)
                RETURN r
                """

                db.cypher_query(query)
                harness_input_node.save()

        except Exception as e:
            pass

    return harness_input_node
```

**Concurrency Handling**:
1. Try to create node
2. If creation fails (duplicate), another thread won
3. Winner thread creates relationships
4. Loser thread returns early
5. Use `db.write_transaction` for atomic operations

**Race Condition Mitigation**:
- Unique identifiers prevent duplicates
- Transaction rollback on conflict
- Retry with `get_or_none` after failure

## Query Examples

### Find Uncovered Functions

```python
# Query for functions not covered by any input
result = db.cypher_query("""
    MATCH (f:CFGFunction)
    WHERE NOT (f)<-[:COVERS]-(:HarnessInputNode)
    RETURN f.identifier, f.function_name
    LIMIT 100
""")
```

### Find POVs in Bucket

```python
# Get all POVs in a specific bucket
result = db.cypher_query("""
    MATCH (b:BucketNode {bucket_key: $bucket_key})-[:CONTAIN_POV_REPORT]->(p:PoVReportNode)
    RETURN p.key, p.content
""", {"bucket_key": bucket_key})
```

### Find Patches That Fix POV

```python
# Get all patches that mitigate a specific POV
result = db.cypher_query("""
    MATCH (patch:GeneratedPatch)-[:MITIGATED_POV_REPORT]->(pov:PoVReportNode {key: $pov_key})
    RETURN patch.patch_key, patch.diff, patch.patcher_name
    ORDER BY patch.time_created DESC
""", {"pov_key": pov_key})
```

### Find Call Graph Paths

```python
# Find call paths from covered function to uncovered sink
result = db.cypher_query("""
    MATCH path = (source:CFGFunction)<-[:COVERS]-(input:HarnessInputNode)
    MATCH (sink:CFGFunction {identifier: $sink_key})
    WHERE NOT (sink)<-[:COVERS]-()
    MATCH shortestPath = shortestPath((source)-[:DIRECTLY_CALLS*]->(sink))
    RETURN shortestPath
    LIMIT 1
""", {"sink_key": sink_function_key})
```

## Configuration

**Database Connection** ([__init__.py:5-10](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/__init__.py#L5-L10)):

```python
config.DATABASE_URL = os.environ.get(
    'ANALYSIS_GRAPH_BOLT_URL',
    'bolt://neo4j:helloworldpdt@aixcc-analysis-graph:7687'
)
if os.getenv('CRS_TASK_NUM'):
    config.DATABASE_URL = config.DATABASE_URL.replace('TASKNUM', os.getenv('CRS_TASK_NUM'))
```

**Label Installation** ([__init__.py:21-29](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/__init__.py#L21-L29)):

```python
def install_all_labels():
    for i in range(5):
        try:
            db.install_all_labels()
            break
        except Exception as e:
            log.error(f"Attempt {i+1} to install labels failed: {e}")
            if i == 4 and artiphishell_should_fail_on_error():
                raise
```

**Wipe Project Data** ([__init__.py:31-60](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/__init__.py#L31-L60)):

```python
def wipe_all_nodes_for_project(project_id: str):
    """Wipe all nodes for a given project ID."""
    log.info(f"Wiping all nodes for project {project_id}")

    for node_type in [HarnessInputNode, OrganizerDedupInfoNode, PoVReportNode, GeneratedPatch, DeltaDiffMode]:
        print(f"Wiping nodes of type {node_type.__name__} for project {project_id}")
        try:
            db.cypher_query(
                f"MATCH (n:{node_type.__name__})" + " WHERE n.project_id = $project_id OR n.pdt_project_id = $project_id CALL (n) { WITH n DETACH DELETE n } IN TRANSACTIONS OF 1000 ROWS",
                {'project_id': project_id}
            )
        except Exception as e:
            print("Retry with fewer records")
            db.cypher_query(
                f"MATCH (n:{node_type.__name__})" + " WHERE n.project_id = $project_id OR n.pdt_project_id = $project_id CALL (n) { WITH n DETACH DELETE n } IN TRANSACTIONS OF 100 ROWS",
                {'project_id': project_id}
            )
```

## Performance Characteristics

- **Write Transactions**: Automatic retry on conflict
- **Deduplication**: 15-minute refresh interval
- **Batch Operations**: 1000-10000 rows per transaction
- **Connection**: Bolt protocol with connection pooling
- **Indexes**: Unique indexes on all identifiers
- **Query Optimization**: Raw Cypher for complex joins

## Related Components

All CRS components integrate with Analysis Graph:

- **[Coverage-Guy](../bug-finding/coverage/coverage-guy.md)**: Uploads function-level coverage
- **[POVGuy](../bug-finding/pov-generation/povguy.md)**: Uploads validated POV reports
- **[PatcherG](../patch-generation/patcherg.md)**: Queries POVs, uploads buckets
- **[PatcherQ](../patch-generation/patcherq.md)**: Queries call graphs, uploads patches
- **[AIJON](../bug-finding/vuln-detection/aijon.md)**: Queries uncovered paths
- **[SARIFGuy](../sarif-processing.md)**: Uploads validated SARIF findings

## Library Location

**Source**: [`libs/analysis-graph/`](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/libs/analysis-graph)

**Models**:
- [`models/cfg.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/models/cfg.py) - Function nodes
- [`models/harness_inputs.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/models/harness_inputs.py) - Input nodes
- [`models/crashes.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/models/crashes.py) - POV and patch nodes
- [`api/dynamic_coverage.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/libs/analysis-graph/src/analysis_graph/api/dynamic_coverage.py) - Coverage upload API
