# shellphish-oss-crs

Shellphish CRS (Cybersecurity Reasoning System) integrated into the [OSS-CRS](https://github.com/Team-Atlanta/oss-crs) framework.

## Pipelines

Each pipeline is a self-contained CRS configuration. Deploy by copying its yaml to `oss-crs/crs.yaml`.

### C/C++ Pipelines

| Pipeline | CRS Name | Config | Doc | Description |
|----------|----------|--------|-----|-------------|
| **C Fuzzers** | `crs-shellphish-c-fuzzers` | `crs-c-fuzzers.yaml` | [doc](docs/crs-shellphish-c-fuzzers.md) | AFL++ + LibFuzzer parallel ensemble |
| **DiscoveryGuy** | `crs-shellphish-discoveryguy` | `crs-discoveryguy.yaml` | [doc](docs/crs-shellphish-discoveryguy.md) | LLM-driven vulnerability discovery + AFL++ |
| **AIJON** | `crs-shellphish-aijon` | `crs-aijon.yaml` | [doc](docs/crs-shellphish-aijon.md) | LLM-driven IJON instrumentation + AFL++ |
| **Grammar** | `crs-shellphish-grammar` | `crs-grammar.yaml` | [doc](docs/crs-shellphish-grammar.md) | LLM grammar fuzzing + coverage-guided refinement |

### JVM Pipelines

| Pipeline | CRS Name | Config | Doc | Description |
|----------|----------|--------|-----|-------------|
| **JVM Fuzzers** | `crs-shellphish-jvm-fuzzers` | `crs-jvm-fuzzers.yaml` | [doc](docs/crs-shellphish-jvm-fuzzers.md) | Jazzer (libFuzzer for JVM) + LOSAN sanitizers |
| **QuickSeed** | `crs-shellphish-quickseed` | `crs-quickseed.yaml` | [doc](docs/crs-shellphish-quickseed.md) | LLM-driven seed generation + Jazzer fuzzing |

Note: DiscoveryGuy, AIJON, Grammar pipelines are C/C++ only. backdoorguy (entropy-based suspicious function detection, feeds DiscoveryGuy) is not yet integrated.

## Quick Start

```bash
# 1. Choose a pipeline
cp oss-crs/crs-c-fuzzers.yaml oss-crs/crs.yaml      # C fuzzers
cp oss-crs/crs-jvm-fuzzers.yaml oss-crs/crs.yaml    # Java fuzzers
cp oss-crs/crs-quickseed.yaml oss-crs/crs.yaml      # Java + QuickSeed (LLM)

# 2. Prepare (build prebuild images, first time only)
cd /project/oss-crs
uv run oss-crs prepare --compose-file example/crs-shellphish-c-fuzzers/compose.yaml

# 3. For LLM pipelines (QuickSeed, DiscoveryGuy, Grammar), set API credentials:
export AIXCC_LITELLM_HOSTNAME=<litellm-url>
export LITELLM_KEY=<api-key>

# 4. Run
uv run oss-crs run --compose-file example/crs-shellphish-c-fuzzers/compose.yaml \
  --fuzz-proj-path <target> --target-source-path <source> \
  --target-harness <harness> --timeout 1800
```

> **Note**: Large Java targets (e.g., activemq) may need `--timeout 3600` for the build phase to complete.

### Test Targets

| Language | Target | Source | Harness |
|----------|--------|--------|---------|
| C | `c/sanity-mock-c-delta-01` | `sanity-mock-c` | `fuzz_parse_buffer_section` |
| C | `c/afc-lcms-full-01` | `afc-lcms` | `cmsIT8_load_fuzzer` |
| C | `c/asc-nginx-delta-01` | `asc-nginx` | `pov_harness` |
| JVM | `jvm/sanity-mock-java-delta-01` | `sanity-mock-java` | `OssFuzz1` |
| JVM | `jvm/atlanta-imaging-delta-01` | `atlanta-imaging` | `ImagingOne` |
| JVM | `jvm/atlanta-activemq-delta-01` | `atlanta-activemq` | `ActivemqOne` |

## Reference

- [CLAUDE.md](CLAUDE.md) — Integration rules, glue layer principles, pitfalls encountered
- [docs/](docs/) — Per-pipeline architecture, verification checklists, test results
