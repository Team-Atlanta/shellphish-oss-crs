# Corpus-Guy

Corpus-Guy is an **in-house automated corpus generation system** that uses LLM-based format inference, trace analysis, and static analysis to create intelligent initial seeds for fuzzing. It eliminates manual corpus creation and provides high-quality starting inputs.

## Purpose

- Automated seed generation for fuzzing campaigns
- LLM-based input format inference
- CodeQL-driven dictionary extraction
- Trace-based format detection
- Kickstart mechanism for high-value seed injection

## Architecture

### Pipeline Configuration

**File**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml)

**Key Tasks**:
1. **`corpus_diff_splitter`** ([Lines 26-85](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L26-L85)) - Extract code diffs as seeds
2. **`corpus_inference_llm`** ([Lines 87-218](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L87-L218)) - LLM-based format inference
3. **`corpus_kickstart`** ([Lines 220-319](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L220-L319)) - Inject seeds to fuzzers

## Implementation

### Main Features

**From [README](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/README.md)**:

**1. Format Inference - Trace-Based** (`run_inference_trace`):
- Runs harness with random inputs
- Monitors file operations (open, read, fstat)
- Infers format from I/O patterns
- Extracts format hints (magic bytes, structure)

**2. Format Inference - LLM-Based** (`run_inference_llm`):
- Analyzes project code and harness
- LLM guesses likely input formats
- Considers: file extensions, function names, string literals
- Generates format-specific seeds

**3. Dictionary Extraction** (`run_codeql_extract_dicts`):
- Runs CodeQL queries on database
- Extracts: string literals, integer constants, magic numbers
- Creates AFL++/libFuzzer-compatible dictionaries
- Static analysis for fuzzing constants

**4. Kickstart Mechanism** (`run_kickstart`):
- Syncs high-value seeds from libpermanence
- Injects known crashes from previous runs
- Distributes to active fuzzer instances
- Controlled seed injection

## Workflow

### Diff-Based Seeding

**Task**: `corpus_diff_splitter` ([Lines 26-85](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L26-L85))

**Process**:
1. Extract git diffs from project
2. Use diff hunks as potential mutation seeds
3. Focus fuzzing on changed code areas
4. Helps find regression bugs in patches

### LLM Format Inference

**Task**: `corpus_inference_llm` ([Lines 87-218](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L87-L218))

**Algorithm**:
1. **Context Collection**:
   - Read project README
   - Analyze harness function names
   - Extract file extension patterns
   - Find format-related string literals

2. **LLM Query**:
   - Prompt: "What input format does this project expect?"
   - Context: Project metadata + harness code
   - Output: Format description + example seeds

3. **Seed Generation**:
   - Create format-conforming seed files
   - Save to `likely_input_formats_corpuses` repository
   - Typically 10-100 seeds per format

### CodeQL Dictionary Extraction

**Integration** ([Lines 112-116](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L112-L116)):
```yaml
depends_on:
  codeql_db_ready: codeql_db_ready  # Wait for CodeQL database
```

**Query Types**:
- String literals in comparisons
- Integer constants in conditions
- Enum values
- Magic numbers (0xDEADBEEF, etc.)

**Output**: `dict.txt` files for fuzzers

### Kickstart Mechanism

**Task**: `corpus_kickstart` ([Lines 220-319](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L220-L319))

**Sync to Fuzzers** ([Lines 173-191](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L173-L191)):
```bash
# Controlled by environment variable
CORPUSGUY_SYNC_TO_FUZZER=true

# Target directories
SYNC_TARGETS="/shared/fuzzer_sync/${PROJECT_NAME}-*/sync-corpusguy/queue/"

# Language-specific seed limits
if [ "$LANGUAGE" = "java" ] || [ "$LANGUAGE" = "jvm" ]; then
    SEED_LIMIT=1000
elif [ "$LANGUAGE" = "c" ] || [ "$LANGUAGE" = "c++" ]; then
    SEED_LIMIT=1000
fi

# Copy seeds up to limit
rsync -av --max-files=$SEED_LIMIT \
    {{ likely_input_formats_corpuses }}/ \
    $SYNC_TARGET
```

**Features**:
- Rate limiting (1000 seeds max)
- Language-specific handling
- Atomic updates (rsync)
- Wildcard sync to all harnesses

## Dependencies

### Upstream

**CodeQL** ([Lines 113-116](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L113-L116)):
- `codeql_db_ready`: Database availability signal
- CodeQL queries for dictionary extraction
- Static analysis for constants

**Function Indices** ([Lines 130-137](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L130-L137)):
- `full_functions_indices`: Fast function lookup
- Reachability analysis
- Function code extraction

**Project Metadata**:
- Language detection
- Project structure information
- Harness identification

### Downstream

**All Fuzzers**:
- AFL++, libFuzzer, Jazzer consume seeds
- Dictionaries improve mutation effectiveness
- Seeds kickstart coverage exploration

## Key Algorithms

### Trace-Based Format Detection

**Process**:
1. Run harness with random bytes
2. Intercept libc file operations (LD_PRELOAD)
3. Log: file paths, offsets, read sizes
4. Infer: File format structure, magic bytes, field boundaries
5. Generate: Format-conforming seeds

### LLM Prompt Engineering

**Prompt Structure**:
```
Project: [name]
Language: [C/Java/...]
Harness: [function name]
File operations: [read/write patterns]

Based on this context, what input format does the harness expect?
Provide:
1. Format description
2. Example valid inputs
3. Key structure elements
```

**Budget**: $10 per task (same as Grammar-Guy)

### Diff-Based Seed Extraction

**Algorithm**:
1. Extract git diff hunks
2. Filter: Lines with string literals, byte arrays
3. Extract: Potential input fragments
4. Create: Seeds containing extracted fragments
5. Focus: Fuzz around changed code

## Output Formats

### Seed Corpus

**Repository**: `likely_input_formats_corpuses` ([Lines 140-146](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L140-L146))

**Structure**:
```
likely_input_formats_corpuses/
├── format1/
│   ├── seed_001.dat
│   ├── seed_002.dat
│   └── ...
└── format2/
    └── ...
```

### Dictionary Files

**Format**: AFL++/libFuzzer compatible
```
# Dictionary for magic values
"0xDEADBEEF"
"0x12345678"
"START_MARKER"
"END_MARKER"
"\x89PNG\x0d\x0a"  # PNG magic bytes
```

### Event Logs

**Contents**:
- LLM API calls and responses
- Inferred formats and confidence scores
- Seed generation statistics
- Cost tracking

## Performance Characteristics

### Speed

- **LLM inference**: 1-5 minutes
- **Trace-based**: 10-30 seconds
- **Diff extraction**: Seconds
- **CodeQL queries**: Minutes

### Quality

- **Format accuracy**: 70-90% (LLM-based)
- **Seed validity**: 80-95% produce valid inputs
- **Coverage improvement**: 15-30% vs random seeds

### Resource Usage

- CPU: 1-2 cores
- Memory: 2Gi
- Budget: $3-8 typical LLM costs

## Integration Points

### Sync Mechanism

**Target Directories** ([Lines 173-191](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/corpus-guy/pipeline.yaml#L173-L191)):
```
/shared/fuzzer_sync/${PROJECT_NAME}-${HARNESS}/sync-corpusguy/queue/
```

**Fuzzer Detection**:
- AFL++ reads from sync-corpusguy/queue/
- libFuzzer merges into main corpus
- Jazzer incorporates via same mechanism

## Related Components

- **[CodeQL](../static-analysis/codeql.md)**: Dictionary extraction
- **[Grammar-Guy](./grammar-guy.md)**: Complementary structured generation
- **[AFL++](../fuzzing/aflplusplus.md)**: Primary seed consumer
