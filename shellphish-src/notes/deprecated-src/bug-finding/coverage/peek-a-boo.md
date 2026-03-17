# Peek-a-Boo

Peek-a-Boo is a **manual coverage analysis tool** that wraps OSS-Fuzz's coverage infrastructure (`infra/helper.py coverage`) to generate HTML coverage reports for local testing and validation. Unlike Coverage-Guy, which runs automatically in production, Peek-a-Boo is used interactively for manual corpus evaluation.

## Purpose

- Generate HTML coverage reports for manual inspection
- Support both OSS-Fuzz and Artiphishell corpuses
- Enable local testing and validation
- Provide visualization of seed corpus effectiveness
- Debug coverage issues before deploying to production

## Usage

### Interactive Mode

**Script**: [`run.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/peek-a-boo/run.sh)

```bash
./run.sh
```

**Prompts**:
1. Which corpus would you like to use?
   - `1. OSS-Fuzz corpus` (from Google's OSS-Fuzz)
   - `2. Artiphishell corpus` (from CRS fuzzing runs)

### Artiphishell Corpus Mode

**Script**: [`artiphishell-corpus.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/peek-a-boo/artiphishell-corpus.sh)

**Workflow** ([Lines 1-85](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/peek-a-boo/artiphishell-corpus.sh#L1-L85)):
1. Clone OSS-Fuzz repository to `/tmp/peek-a-boo/oss-fuzz`
2. Download seeds from libpermanence:
   ```bash
   curl -H 'Shellphish-Secret: !!artiphishell!!' \
     "http://beatty.unfiltered.seclab.cs.ucsb.edu:31337/download_corpus/$PROJECT_NAME/$HARNESS_NAME" \
     --output "$HARNESS_NAME-seeds.tar.gz"
   ```
3. Extract seeds to corpus directory
4. Copy coverage-instrumented artifacts to OSS-Fuzz build directory
5. Run OSS-Fuzz coverage analysis:
   ```bash
   python3 infra/helper.py coverage "$PROJECT_NAME" \
     --no-corpus-download \
     --corpus-dir="$CORPUS_DIR" \
     --fuzz-target="$HARNESS_NAME" \
     --port="$PORT_NUM"
   ```
6. Copy HTML report to `/peekaboo/report/$PROJECT_NAME/$HARNESS_NAME`

**Arguments**:
- `$1`: Project name (e.g., `hiredis`)
- `$2`: Harness name (e.g., `hiredis_fuzzer`)
- `$3`: Project directory (optional)
- `$4`: Project URL (optional, for custom builds)

### OSS-Fuzz Corpus Mode

**Script**: [`oss-fuzz-corpus.sh`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/peek-a-boo/oss-fuzz-corpus.sh)

Similar workflow, but uses OSS-Fuzz's default corpus instead of Artiphishell seeds.

## Integration with CRS

### Corpus Sources

**1. OSS-Fuzz Corpus**:
- Default seed corpora provided by OSS-Fuzz
- Located in OSS-Fuzz repository
- Typically small, hand-crafted seeds

**2. Artiphishell Corpus (CRS)** ([Lines 42-64](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/peek-a-boo/artiphishell-corpus.sh#L42-L64)):
```bash
# Download from libpermanence
SEEDS_TAR_FILE="$TMP_DIR/$HARNESS_NAME/$HARNESS_NAME-seeds.tar.gz"
curl -H 'Shellphish-Secret: !!artiphishell!!' \
    "http://beatty.unfiltered.seclab.cs.ucsb.edu:31337/download_corpus/$PROJECT_NAME/$HARNESS_NAME" \
    --output "$SEEDS_TAR_FILE" --fail

# Extract
CORPUS_DIR="/tmp/peek-a-boo/$PROJECT_NAME/$HARNESS_NAME"
tar -xzf "$SEEDS_TAR_FILE" -C "$CORPUS_DIR"
SEED_COUNT=$(find "$CORPUS_DIR" -type f | wc -l)

echo "We have $SEED_COUNT seeds in $CORPUS_DIR"
```

**Libpermanence**: CRS service that archives high-value seeds from fuzzing runs.

### Coverage Build Artifacts ([Lines 52-54](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/peek-a-boo/artiphishell-corpus.sh#L52-L54))

```bash
TARGET_OUT_DIR="$OSS_FUZZ_DIR/build/out/$PROJECT_NAME/"
mkdir -p "$TARGET_OUT_DIR"
cp -r $PROJECT_DIR/artifacts/out/* $TARGET_OUT_DIR
```

**Artifacts**:
- Instrumented binaries with coverage support
- Built with `--sanitizer coverage --instrumentation coverage_fast`
- Same as used by Coverage-Guy

### HTML Report Generation

**OSS-Fuzz Coverage Tool** ([Lines 69-76](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/peek-a-boo/artiphishell-corpus.sh#L69-L76)):
```bash
python3 infra/helper.py coverage "$PROJECT_NAME" \
  --no-corpus-download \
  --corpus-dir="$CORPUS_DIR" \
  --fuzz-target="$HARNESS_NAME" \
  --port="$PORT_NUM"
```

**Report Output** ([Lines 78-85](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/peek-a-boo/artiphishell-corpus.sh#L78-L85)):
```bash
# OSS-Fuzz writes to: $OSS_FUZZ_DIR/build/out/$PROJECT_NAME/report
# Copy to standardized location
cp -r $OSS_FUZZ_DIR/build/out/$PROJECT_NAME/report \
    /peekaboo/report/$PROJECT_NAME/$HARNESS_NAME
```

**Report Contents**:
- HTML coverage report with line-by-line highlighting
- Coverage percentages per file
- Uncovered code regions
- Function-level coverage statistics

## Use Cases

### 1. Manual Corpus Evaluation
- Download corpus from libpermanence
- Generate coverage report
- Inspect HTML to identify gaps
- Decide if manual seeds are needed

### 2. Grammar Validation
- Test grammar-generated seeds
- Compare coverage before/after grammar refinement
- Validate that Grammar-Guy improvements work

### 3. Debugging Coverage Issues
- Local testing without Kubernetes overhead
- Quick iteration on corpus changes
- Verify instrumentation is working correctly

### 4. Baseline Comparison
- Compare Artiphishell corpus vs OSS-Fuzz corpus
- Quantify coverage improvements from CRS
- Generate reports for documentation

## Differences from Coverage-Guy

| Feature | Coverage-Guy | Peek-a-Boo |
|---------|-------------|------------|
| **Mode** | Automated, production | Manual, interactive |
| **Scope** | All seeds, real-time | Single corpus snapshot |
| **Output** | Neo4j graph | HTML reports |
| **Purpose** | Analysis graph data | Human inspection |
| **Deployment** | Kubernetes, long-running | Local script |
| **Parallelism** | 4 tracers + 4 uploaders | Single process |
| **Integration** | PDT streaming repos | Static corpus directory |

## Related Components

- **[Coverage-Guy](./coverage-guy.md)**: Automated production coverage monitoring
- **[Grammar-Guy](../grammar/grammar-guy.md)**: Uses coverage data for refinement
- **[Corpus-Guy](../grammar/corpus-guy.md)**: Generates seeds for testing
- **[Libpermanence](../../infrastructure/libpermanence.md)**: Seed archive service
