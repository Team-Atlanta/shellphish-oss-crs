# Jazzer

Jazzer is a coverage-guided fuzzer for the JVM that the CRS uses for Java/Kotlin fuzzing. The integration includes a **Shellphish-enhanced version** with LOSAN detection, CodeQL-guided fuzzing, and in-scope package filtering.

## Purpose

- JVM bytecode fuzzing with libFuzzer engine
- Java/Kotlin application security testing
- LOSAN (LOgic and Semantic bug ANalysis) detection
- CodeQL integration for guided fuzzing

## CRS-Specific Enhancements

**Pipeline**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml)

### Three Jazzer Variants

**1. Original Jazzer** - `jazzer_fuzz` ([Lines 244-460](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L244-L460)):
- Standard Jazzer from GitHub
- Binary: `/out/jazzer_driver.orig`

**2. Shellphish Jazzer** - `jazzer_fuzz_shellphish` ([Lines 462-679](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L462-L679)):
- **Custom binary**: `/out/shellphish/jazzer-aixcc/jazzer_driver`
- **LOSAN detection**: Separate crash directory for logic bugs ([Lines 421, 641](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L421))
- **In-scope filtering**: `instrumentation_and_strings.py` generates package whitelist ([Lines 672-675](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L672-L675))

**3. CodeQL-Guided Jazzer** - `jazzer_fuzz_shellphish_codeql` ([Lines 681-906](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L681-L906)):
- **Dynamic dictionary**: CodeQL query `java_strings_for_dict.ql` ([Line 897](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L897))
- **Reachability analysis**: `java_reaching_funcs.ql.j2` for target classes ([Line 898](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L898))
- **Metadata-driven**: Project metadata controls scope ([Line 892](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L892))

### LOSAN Detection

**Purpose**: Find logic/semantic bugs beyond crashes

**Implementation** ([Lines 419-422](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L419-L422)):
```bash
BENIGN_DIR=.../benign_queue/
CRASH_DIR=.../crashes/
LOSAN_DIR=.../losan_crashes/  # Logic bugs
```

**Detection Criteria**:
- Unexpected exceptions (not crashes)
- Invariant violations
- Semantic errors in application logic

### CodeQL Integration

**Dictionary Extraction** ([Lines 895-901](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L895-L901)):
```bash
# Run CodeQL query to extract strings
codeql query run java_strings_for_dict.ql

# Generate dictionary file
cat results.csv | cut -d',' -f2 > /out/codeql.dict
```

**In-Scope Packages** ([Lines 448-454](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L448-L454)):
```json
{
  "in_scope_packages": ["com.project.*"],
  "out_of_scope_packages": ["java.lang.*", "org.junit.*"]
}
```

### Corpus Management

**Three Corpus Types** ([Lines 410-422](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L410-L422)):
1. Benign queue: Normal coverage-expanding inputs
2. Crashes: Traditional crashing inputs
3. LOSAN crashes: Logic/semantic bugs

**Sync Directories** ([Lines 431-434](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L431-L434)):
- Standard sync: `/shared/fuzzer_sync/${PROJECT}-${HARNESS}/`
- Quickseed injection: Pre-generated seeds
- Minimized corpus: Separate directory for optimized corpus

### Resource Configuration

**High Concurrency** ([Lines 254-260](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L254-L260)):
```yaml
max_concurrent_jobs: 3000  # Same as AFL++
job_quota:
  cpu: 1
  mem: "2Gi"
```

### Grammar Integration

**Nautilus Support** ([jazzer_build Lines 156-158](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/jazzer/pipeline.yaml#L156-L158)):
```bash
rsync -av /shellphish/libs/nautilus/grammars/reference/ \
    ${BUILD_ARTIFACT}/grammars/
```

## Related Components

- **[CodeQL](../static-analysis/codeql.md)**: Dictionary and reachability analysis
- **[Corpus-Guy](../grammar/corpus-guy.md)**: Java-specific seed generation
