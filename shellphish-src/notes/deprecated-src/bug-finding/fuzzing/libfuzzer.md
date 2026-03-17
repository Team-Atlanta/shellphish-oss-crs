# libFuzzer

libFuzzer is LLVM's in-process, coverage-guided fuzzer that the CRS uses for fast C/C++ fuzzing. The integration focuses on multi-replica corpus synchronization, high-resource instances, and continuous corpus minimization.

## Purpose

- In-process fuzzing for C/C++ with minimal overhead
- High throughput (10-100k execs/sec)
- Complement AFL++ with different mutation strategies
- Per-harness corpus management with cross-node sync

## CRS-Specific Integration

**Pipeline**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/libfuzzer/pipeline.yaml)

### Key Features

**1. High-Resource Instances** ([Lines 114-119](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/libfuzzer/pipeline.yaml#L114-L119)):
```yaml
job_quota:
  cpu: 5      # 5x more than AFL++
  mem: "8Gi"  # 4x more than AFL++
max_concurrent_jobs: 20
```

**2. Per-Replica Directories** ([Lines 258-269](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/libfuzzer/pipeline.yaml#L258-L269)):
```bash
BASE_DIR=/shared/libfuzzer/fuzz/${PROJECT}-${HARNESS}-${HARNESS_INFO_ID}
REPLICA_DIR=${BASE_DIR}/${REPLICA_NUM}

mkdir -p $REPLICA_DIR/corpus
mkdir -p $REPLICA_DIR/crashes
mkdir -p $REPLICA_DIR/benign
```

**3. Continuous Minimization** - Separate task `libfuzzer_fuzz_same_node_sync` ([Lines 293-420](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/libfuzzer/pipeline.yaml#L293-L420)):
- Runs periodically
- Merges corpus from all replicas
- Minimizes to smallest inputs per coverage

**4. Cross-Node Sync** ([Lines 421-510](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/libfuzzer/pipeline.yaml#L421-L510)):
```bash
# SSH-based rsync via cross_node_sync_seeds.sh
rsync -avz ${LOCAL_CORPUS}/ root@${REMOTE_NODE}:${REMOTE_CORPUS}/
```

### Corpus Management

**Sync Path** ([Lines 277-279](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/libfuzzer/pipeline.yaml#L277-L279)):
```bash
SYNC_DIR=/shared/fuzzer_sync/${LIBFUZZER_INSTANCE_UNIQUE_NAME}/
```

**Dictionary** ([Line 289](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/libfuzzer/pipeline.yaml#L289)):
```bash
# Auto-generated or from corpus-guy
-dict=/out/dict.txt
```

### No Custom Modifications

- Uses **standard LLVM libFuzzer** binary
- No source code modifications
- Customization via wrapper scripts only

## Related Components

- **[AFL++](./aflplusplus.md)**: Complementary fuzzer
- **[Corpus-Guy](../grammar/corpus-guy.md)**: Initial seeds
