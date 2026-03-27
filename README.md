# shellphish-oss-crs

Shellphish CRS (Cybersecurity Reasoning System) integrated into the [OSS-CRS](https://github.com/Team-Atlanta/oss-crs) framework.

## Pipelines

Each pipeline is a self-contained CRS configuration. Deploy by copying its yaml to `oss-crs/crs.yaml`.

| Pipeline | CRS Name | Config | Doc |
|----------|----------|--------|-----|
| **C Fuzzers** | `crs-shellphish-c-fuzzers` | `oss-crs/crs-c-fuzzers.yaml` | [docs/crs-shellphish-c-fuzzers.md](docs/crs-shellphish-c-fuzzers.md) |
| **DiscoveryGuy** | `crs-shellphish-discoveryguy` | `oss-crs/crs-discoveryguy.yaml` | docs/crs-shellphish-discoveryguy.md |
| **AIJON** | `crs-shellphish-aijon` | `oss-crs/crs-aijon.yaml` | docs/crs-shellphish-aijon.md |
| **Grammar** | `crs-shellphish-grammar` | `oss-crs/crs-grammar.yaml` | docs/crs-shellphish-grammar.md |

## Quick Start

```bash
# 1. Choose a pipeline
cp oss-crs/crs-c-fuzzers.yaml oss-crs/crs.yaml

# 2. From oss-crs repo:
uv run oss-crs prepare --compose-file example/crs-shellphish-c-fuzzers/compose.yaml
uv run oss-crs build-target --compose-file example/crs-shellphish-c-fuzzers/compose.yaml \
  --fuzz-proj-path <target> --target-source-path <source>
uv run oss-crs run --compose-file example/crs-shellphish-c-fuzzers/compose.yaml \
  --fuzz-proj-path <target> --target-source-path <source> \
  --target-harness <harness> --timeout 300
```

## Reference

- [CLAUDE.md](CLAUDE.md) — Integration rules, glue layer principles, pitfalls encountered
- [docs/](docs/) — Per-pipeline architecture, verification checklists, design decisions
