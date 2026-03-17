# ClusterFuzz

ClusterFuzz is Google's fuzzing infrastructure that the CRS integrates via OSS-Fuzz. This provides access to Google's distributed fuzzing platform with minimal customization.

## Purpose

- Leverage Google's OSS-Fuzz infrastructure
- Long-running distributed fuzzing campaigns
- Multi-engine support (libFuzzer, AFL++, Honggfuzz)
- High-resource fuzzing (16 CPU cores per job)

## CRS-Specific Usage

**Pipeline**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clusterfuzz/pipeline.yaml)

### Integration Approach

**OSS-Fuzz Helper** ([Lines 74-76](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clusterfuzz/pipeline.yaml#L74-L76)):
```bash
python3 /oss-fuzz/infra/helper.py build_image ${PROJECT} --external
python3 /oss-fuzz/infra/helper.py build_fuzzers ${PROJECT} --external
python3 /oss-fuzz/infra/helper.py check_build ${PROJECT}
```

**External Project Mode**:
- `--external` flag adapts OSS-Fuzz for non-public projects
- Requires: `build.sh`, `Dockerfile`, `project.yaml` in source

### Resource Configuration

**High CPU Allocation** ([Lines 90-93](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clusterfuzz/pipeline.yaml#L90-L93)):
```yaml
job_quota:
  cpu: 16      # Highest CPU allocation
  mem: "32Gi"  # Highest memory allocation
```

### Fuzzer Execution

**Run Fuzzer** ([Line 173](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clusterfuzz/pipeline.yaml#L173)):
```bash
python3 /oss-fuzz/infra/helper.py run_fuzzer \
    ${PROJECT} ${HARNESS}
```

Uses OSS-Fuzz's standard fuzzing infrastructure with no modifications.

### Output

**Corpus Collection** ([Lines 104-141](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/clusterfuzz/pipeline.yaml#L104-L141)):
- Crash corpus with coverage
- Benign corpus
- Same format as other fuzzers

## Key Features

**Multi-Engine Support**:
- libFuzzer (default)
- AFL++
- Honggfuzz
- Configurable per project

**Language Support**:
- C/C++, Rust, Go
- Python, Java/JVM, JavaScript

**Standard OSS-Fuzz**:
- No custom modifications
- Leverages Google's infrastructure
- Minimal CRS-specific integration

## Related Components

- **[libFuzzer](./libfuzzer.md)**: Default fuzzing engine
- **[AFL++](./aflplusplus.md)**: Alternative engine
