# Crash-Tracer

Crash-Tracer parses raw sanitizer outputs (ASAN, MSAN, UBSAN, libFuzzer) from fuzzer crashes and converts them into structured `ASANReport` YAML format. It handles 30+ crash types, extracts stack traces, and categorizes crashes by sanitizer and crash type.

## Purpose

- Parse stderr/stdout from sanitizer crashes
- Extract structured crash information
- Support ASAN, MSAN, UBSAN, LeakSanitizer, libFuzzer
- Generate `ASANReport` YAML for downstream analysis

## Implementation

**Main File**: [`asan2report.py`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/asan2report.py)

**Pipeline**: [`pipeline.yaml`](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/pipeline.yaml)

## Stack Trace Parsing

### Source Code Location ([Lines 39-56](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/asan2report.py#L39-L56))

```python
def parsed_stack_trace(stack_trace):
    trace = []
    for line in stack_trace.splitlines():
        # Example: #3 0x55d9c0a2b3f4 in handle_request /src/nginx/src/http/ngx_http_request.c:1234:5
        res = re.search(r'#(\d+)\s+(0x[0-9a-fA-F]+)\s+in\s+', line)
        if not res:
            continue

        depth = int(res.group(1))
        addr = int(res.group(2), 16)
        line = line[len(res.group(0)):]

        # Extract file:line
        if res := re.search(r'([^\s]*):(\d+):\d+$', line) or re.search(r'([^\s]*):(\d+)$', line):
            file = Path(res.group(1)).resolve()
            if str(file).startswith('/src'):
                file = Path("src") / file.relative_to("/src")
            line_num = int(res.group(2))
            signature = line[:-len(res.group(0))].strip()

            trace.append({
                'depth': depth,
                'type': 'source',
                'src_loc': f"{file}:{line_num}",
                'src_file': file,
                'line': line_num,
                'signature': signature
            })
```

### Binary Location ([Lines 77-100](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/asan2report.py#L77-L100))

```python
# Example: #5 0x7f3a2c8d1e23 in __libc_start_main (/lib/x86_64-linux-gnu/libc.so.6+0x21e23) (BuildId: 1234abcd)
elif res := re.search(r'\s+\(BuildId:\s+([0-9a-fA-F]+)\)$', line):
    build_id = res.group(1)
    line = line[:-len(res.group(0))]
    res = re.search(r'([^(]+)\+0x([0-9a-fA-F]+)', line)
    binary = Path(res.group(1)).resolve()
    offset = int(res.group(2), 16)
    signature = line[:line.index(res.group(1))][:-1].strip()

    trace.append({
        'depth': depth,
        'type': 'binary',
        'binary': binary,
        'offset': offset,
        'build_id': build_id,
        'signature': signature
    })
```

## Crash Type Detection

### Sanitizer and Crash Type Extraction ([Lines 273-323](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/asan2report.py#L273-L323))

```python
def _parse_report(self):
    line = io.readline()

    # Extract sanitizer
    if '==ERROR: ' in line:
        line = line.split('==ERROR: ')[1]
    elif '==WARNING: ' in line:
        line = line.split('==WARNING: ')[1]

    self.sanitizer = line.split(':')[0].strip().split()[0]

    match self.sanitizer:
        case 'AddressSanitizer':
            if ': attempting double-free' in line:
                crash_type = 'double-free'
            elif ': attempting free on address which was not malloc()-ed' in line:
                crash_type = 'bad-free'
            elif 'AddressSanitizer failed to allocate' in line:
                crash_type = 'out-of-memory'
            else:
                # Example: "AddressSanitizer: heap-buffer-overflow on address 0x..."
                crash_type = line.split('AddressSanitizer: ')[1].split(':')[0].strip().split()[0]
            self.crash_type = crash_type

        case 'MemorySanitizer':
            crash_type = line.split("MemorySanitizer: ")[1].split(':')[0].strip()
            if crash_type != 'CHECK failed':
                crash_type = crash_type.split()[0]
            self.crash_type = crash_type

        case 'UndefinedBehaviorSanitizer':
            crash_type = line.split("UndefinedBehaviorSanitizer: ")[1].split()[0].strip()
            self.crash_type = crash_type

        case 'libFuzzer':
            self.crash_type = line.split('libFuzzer:')[1].strip().split('(')[0].strip()
```

### Null-Pointer vs Wild-Pointer Deref ([Lines 327-338](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/asan2report.py#L327-L338))

```python
# Refine SEGV crash types
if self.crash_type == 'SEGV':
    assert 'unknown address' in line
    address = line[line.index('unknown address')+len('unknown address'):].strip().split()[0]

    if 'unknown address (pc' not in line:
        addr = int(address, 16)
        if addr == 0:
            crash_type = 'null-ptr-deref'
        else:
            crash_type = 'wild-ptr-deref'
    else:
        crash_type = 'wild-ptr-deref'

    self.internal_crash_type = crash_type
```

## Stack Trace Categorization

### Heap Use-After-Free ([Lines 367-369](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/asan2report.py#L367-L369))

```python
case 'heap-use-after-free' | 'double-free':
    stack_traces['free'] = traces[1] if len(traces) >= 2 else ''
    stack_traces['allocate'] = traces[2] if len(traces) >= 3 else ''
```

**Output**:
- `main`: Crash site
- `free`: Where object was freed
- `allocate`: Where object was allocated

### Heap Buffer Overflow ([Lines 365-366](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/asan2report.py#L365-L366))

```python
case 'heap-buffer-overflow' | 'container-overflow' | 'use-after-poison':
    stack_traces['allocate'] = traces[1] if len(traces) >= 2 else ''
```

**Output**:
- `main`: Crash site
- `allocate`: Where buffer was allocated

### Stack Buffer Overflow ([Lines 370-372](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/asan2report.py#L370-L372))

```python
case 'stack-buffer-overflow' | 'bad-free' | 'stack-use-after-return':
    stack_traces['crashing-address-frame'] = traces[1] if len(traces) >= 2 else ''
    stack_traces['frame-info'] = traces[2] if len(traces) >= 3 else ''
```

## Crash Action Extraction

### Access Type and Size ([Lines 391-425](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/asan2report.py#L391-L425))

```python
match self.sanitizer:
    case 'AddressSanitizer':
        if self.crash_type in ['null-ptr-deref', 'wild-ptr-deref', 'SEGV']:
            # Example: "READ of size unknown a unknown address 0x00000000"
            self.crash_action["access"] = elems[elems.index('a')+1]  # READ/WRITE
            self.crash_action["size"] = 'unknown'

        elif self.crash_type in ['heap-buffer-overflow', 'stack-buffer-overflow']:
            # Example: "WRITE of size 8 at 0x7fff..."
            self.crash_action["access"] = elems[0].lower()  # read/write
            self.crash_action["size"] = int(elems[elems.index('size')+1])
```

## ASANReport Structure

```yaml
# Output format
project_id: "proj-abc123"
harness_info_id: "harness-def456"
crash_report_id: "crash-789"

consistent_sanitizers: ["address"]
inconsistent_sanitizers: []
sanitizer_history: ["address", "address"]

cp_harness_id: "harness_1"
cp_harness_name: "test_fuzzer"
fuzzer: "aflplusplus"

sanitizer: "AddressSanitizer: heap-buffer-overflow"
crash_type: "heap-buffer-overflow"

stack_traces:
  main:
    - depth: 0
      type: source
      src_loc: "src/foo.c:42"
      src_file: "src/foo.c"
      line: 42
      signature: "int vulnerable_function(char *buf)"
    - depth: 1
      type: source
      src_loc: "src/bar.c:123"
      line: 123
      signature: "void caller()"

  allocate:
    - depth: 0
      type: source
      src_loc: "src/foo.c:30"
      line: 30
      signature: "char* allocate_buffer()"
```

## Integration

**Pipeline** ([pipeline.yaml Lines 9-43](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/crash-tracer/pipeline.yaml#L9-L43)):
```yaml
tasks:
  asan2report:
    links:
      representative_crash_metadata_path:
        repo: representative_crash_metadatas
        kind: InputFilepath

      parsed_asan_report:
        repo: parsed_asan_reports
        kind: OutputFilepath

    executable:
      template: |
        python3 /asan2report/asan2report.py \
          {{representative_crash_metadata_path | shquote}} \
          {{parsed_asan_report | shquote}}
```

## Related Components

- **[Crash Exploration](./crash-exploration.md)**: Uses parsed reports to explore crash neighborhoods
- **[Invariant-Guy](./invariant-guy.md)**: Uses crash reports to identify POI for invariant mining
- **[POV-Guy](../pov-generation/pov-guy.md)**: Uses crash types for exploit generation
