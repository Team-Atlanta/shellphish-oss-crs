# Vuln Detect Model

Vuln Detect Model is an **LLM-based vulnerability scanner** that analyzes function-level code snippets to detect CWE vulnerabilities. It uses a fine-tuned Qwen2.5-7B model to scan all functions extracted by clang-indexer, focusing on 7 C/C++ and 8 Java high-priority CWE categories.

## Purpose

- AI-powered vulnerability detection at function level
- Detect vulnerabilities before fuzzing triggers them
- Focus on high-risk CWE categories
- GPU-accelerated inference for fast scanning
- Prioritize functions for deeper analysis

## Implementation

**Main Files**:
- [`vuln_scan.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py) - Scanner implementation
- [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/pipeline.yaml) - PDT task configuration
- [`cwe-details.csv`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/cwe-details.csv) - CWE descriptions database

## CWE Categories

### C/C++ ([Lines 54-55](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py#L54-L55))

```python
CWE_IN_SCOPE_SEMI = {
    "c": [125, 787, 119, 416, 415, 476, 190],
    "java": [22, 77, 78, 94, 190, 434, 502, 918]
}
```

**C/C++ CWEs**:
- **CWE-125**: Out-of-bounds Read
- **CWE-787**: Out-of-bounds Write
- **CWE-119**: Improper Restriction of Operations within the Bounds of a Memory Buffer
- **CWE-416**: Use After Free
- **CWE-415**: Double Free
- **CWE-476**: NULL Pointer Dereference
- **CWE-190**: Integer Overflow or Wraparound

**Java CWEs**:
- **CWE-22**: Path Traversal
- **CWE-77**: Command Injection
- **CWE-78**: OS Command Injection
- **CWE-94**: Code Injection
- **CWE-190**: Integer Overflow
- **CWE-434**: Unrestricted Upload of File with Dangerous Type
- **CWE-502**: Deserialization of Untrusted Data
- **CWE-918**: Server-Side Request Forgery (SSRF)

## LLM Prompt Structure

### System Prompt ([Line 13](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py#L13))

```python
sys_prompt = "You are a helpful and harmless assistant. You are Qwen developed by Alibaba. You should think step-by-step."
```

### User Prompt Template ([Lines 19-52](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py#L19-L52))

```python
reasoning_user_prompt = """\
You are an advanced vulnerability detection model. \
Your task is to check if a specific vulnerability exists in a given piece of code. \
You need to output whether the code is vulnerable and the type of vulnerability present with cwe id (CWE-xx). \n

## You are given the following code snippet:
```
{CODE}
```
\n
{CWE_INFO}
\n
{REASONING}
\n
## Final Answer
#judge: <yes/no>
#type: <vulnerability type>

## Additional Constraint:
- If `#judge: yes`, then `#type:` **must contain exactly one CWE**.
- If `#judge: yes`, the model must output **only the most probable CWE** related to the given code snippet.

## Example
- If the code is vulnerable to a CWE-79, you should finally output:
## Final Answer
#judge: yes
#type: CWE-79

- If the code does not contain vulnerabilities related to the given CWE, you should finally output:
## Final Answer
#judge: no
#type: N/A
"""
```

### CWE Information Injection ([Lines 80-85](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py#L80-L85))

```python
policy = policy_prefix  # "You should only focusing on checking if the code contains the following cwe: "
for cwe_number in cwe_in_scope:
    cwe_id = f"CWE-{cwe_number}"
    policy += f"\n- {cwe_id}: {get_cwe_info(cwe_number)}"  # Fetch description from cwe-details.csv
    assert "Unknown CWE" not in policy, f"Unknown CWE: {cwe_id} is detected"
```

## Scanning Workflow

### 1. Function Iteration ([Lines 88-100](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py#L88-L100))

```python
name_to_message = {}
for subdir in ("FUNCTION", "MACRO", "METHOD"):
    dir_path = os.path.join(args.clang_indices, subdir)
    for fname in os.listdir(dir_path):
        if not fname.endswith(".json"):
            continue
        if fname in final_res:  # Skip already scanned
            continue

        file_path = os.path.join(dir_path, fname)
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        if len(data["code"]) > 20000:  # Skip very long functions
            print(f"Code snippet too long: {fname}")
            continue
```

**Input Format** (from clang-indexer):
```json
{
  "signature": "int vulnerable_function(char *buf, size_t len)",
  "file": "/src/project/foo.c",
  "start_line": 42,
  "end_line": 65,
  "code": "int vulnerable_function(char *buf, size_t len) {\n  char stack_buf[16];\n  memcpy(stack_buf, buf, len); // CWE-787: Out-of-bounds Write\n  return 0;\n}\n"
}
```

### 2. Message Construction ([Lines 101-112](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py#L101-L112))

```python
name_to_message[fname] = [
    {"role": "system", "content": sys_prompt},
    {
        "role": "user",
        "content": reasoning_user_prompt.format(
            CODE=data["code"],
            CWE_INFO=policy,  # All CWEs in scope with descriptions
            REASONING=reasoning,
            ADDITIONAL_CONSTRAINT="",
        ),
    },
]
```

### 3. Batch Inference ([Lines 117-133](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py#L117-L133))

```python
BATCH_SIZE = 1000
for i in range(0, len(messages), BATCH_SIZE):
    print(f"Processing batch {i} ~ {i + BATCH_SIZE - 1}")
    batch_messages = messages[i:i + BATCH_SIZE]
    batch_keys = all_keys[i:i + BATCH_SIZE]

    try:
        resps, latencies = asyncio.run(
            model.batch_chat_completion(
                batch_messages,
                temperature=args.temperature,
                max_tokens=8192,
            )
        )
    except Exception as e:
        print(f"Batch failed: {e}")
        continue
```

### 4. Result Saving ([Lines 135-148](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py#L135-L148))

```python
for idx, key in enumerate(batch_keys):
    try:
        final_res[key] = {
            "req": name_to_message[key][1]["content"],  # Original prompt
            "res": resps[idx].choices[0].message.content,  # LLM response
        }
    except Exception as e:
        print(f"Failed to save result for {key}: {e}")

# Save after each batch
with open(result_file, "w") as f:
    json.dump(final_res, f, indent=2)

print(f"[+] Batch {i} ~ {i + BATCH_SIZE - 1} saved to {result_file}")
```

## Model Configuration

### LiteLLM Integration ([Lines 70-78](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py#L70-L78))

```python
# Initialize the rate limiter and the LLM model
limiter = AsyncLimiter(args.requests_per_minute, 60)  # Default: 180 req/min
model = LiteLLMModel(
    model="hosted_vllm/" + args.model_name,
    server_url=args.server_url,  # Default: http://localhost:25001/v1
    limiter=limiter,
    temperature=args.temperature,  # Default: 0.5
    api_key=args.api_key or None,
)
```

**Default Model** ([Line 191](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/vuln_scan.py#L191)):
```
secmlr/DS-Noisy_DS-Clean_QWQ-Noisy_QWQ-Clean_Qwen2.5-7B-Instruct_full_sft_1e-5
```

This is a **fine-tuned Qwen2.5-7B** model trained on vulnerability detection datasets.

## Output Format

**`result_all.json`**:
```json
{
  "foo.c_42_5_vulnerable_function.json": {
    "req": "You are an advanced vulnerability detection model. [...]\n```\nint vulnerable_function(char *buf, size_t len) { ... }\n```\n[...]\n## Final Answer\n#judge: <yes/no>\n#type: <vulnerability type>",
    "res": "## Analysis\nThe function `vulnerable_function` takes a buffer pointer and a length. It copies data from the input buffer to a fixed-size stack buffer without bounds checking...\n\n## Final Answer\n#judge: yes\n#type: CWE-787"
  },
  "bar.c_100_3_safe_function.json": {
    "req": "[...]",
    "res": "## Analysis\nThe function performs bounds checking before accessing the buffer...\n\n## Final Answer\n#judge: no\n#type: N/A"
  }
}
```

## Pipeline Integration

**Configuration** ([pipeline.yaml Lines 13-74](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/vuln_detect_model/pipeline.yaml#L13-L74)):

```yaml
tasks:
  vuln_model_scan:
    job_quota:
      cpu: 1
      mem: 4Gi
    max_concurrent_jobs: 40  # High parallelism

    # GPU node selection
    node_labels:
      "support.shellphish.net/only-gpu": "true"
    node_taints:
      "support.shellphish.net/only-gpu": "true"
    node_affinity:
      "support.shellphish.net/only-gpu": "true"

    links:
      functions_json_dir:
        repo: full_functions_jsons_dirs  # From clang-indexer
        kind: InputFilepath

      vuln_model_report_path:
        repo: vuln_model_report
        kind: OutputFilepath

    executable:
      image: aixcc-vuln-model
      template: |
        export FUNCTIONS_JSON_DIR={{ functions_json_dir | shquote }}
        export LANGUAGE={{ project_metadata.language | shquote }}
        cd /app/
        /app/run_scan.sh
        cp /app/result_all.json {{ vuln_model_report_path | shquote }}
```

## Performance Characteristics

- **Throughput**: 180 functions/minute (rate limited)
- **Batch size**: 1000 functions per batch
- **GPU**: Dedicated nodes for inference
- **Max tokens**: 8192 per response
- **Temperature**: 0.5 (balanced exploration)
- **Parallelism**: Up to 40 concurrent scanning jobs

## Related Components

- **[Clang Indexer](../static-analysis/clang-indexer.md)**: Provides function code snippets
- **[AIJON](./aijon.md)**: Uses vulnerability reports for instrumentation
- **[CodeQL](../static-analysis/codeql.md)**: Complementary static analysis
