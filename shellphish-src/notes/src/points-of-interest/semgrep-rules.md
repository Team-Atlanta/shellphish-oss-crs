# Semgrep Rules

## Overview

Semgrep identifies vulnerability patterns using lightweight syntactic and semantic rules. The CRS uses custom rule sets tailored to detect common vulnerability classes in both Java and C/C++ targets.

**Rule Location**: [components/semgrep/rules/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/semgrep/rules)

The CRS maintains separate rule sets per language:
- **Java Rules**: 8 rule files (21 individual rules)
- **C/C++ Rules**: 1 rule file (1 rule)

## Summary Table

| Language | Vulnerability Type | Rules | CWE/Type | Severity | File |
|----------|-------------------|-------|----------|----------|------|
| Java | Path Traversal (Zip Slip) | 17 | PathTraversal | ERROR | [2-zip-slip.yml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/path-traversal/2-zip-slip.yml) |
| Java | Deserialization | 2 | CWE-502 | WARNING | [1.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/deserialization/1.yaml) |
| Java | Jazzer Patterns | 1 | - | - | [search-jazzer-strings.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/special/search-jazzer-strings.yaml) |
| Java | DSpace CVE | 1 | CVE-2016-10726 | - | [1_DSpace...yml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/cwe_bench/1_DSpace__DSpace_CVE-2016-10726_4.4.yml) |
| Java | Spark CVE | 1 | CVE-2018-9159 | - | [2_perwendel...yml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/cwe_bench/2_perwendel__spark_CVE-2018-9159_2.7.1.yml) |
| Java | HAPI FHIR CVE | 1 | CVE-2023-28465 | - | [46_hapifhir...yml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/cwe_bench/46_hapifhir__org.hl7.fhir.core_CVE-2023-28465_5.6.105.yml) |
| Java | Graylog CVE | 1 | CVE-2023-41044 | - | [47_Graylog2...yml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/cwe_bench/47_Graylog2__graylog2-server_CVE-2023-41044_5.1.2.yml) |
| C/C++ | Out-of-Bounds Write | 1 | CWE-787 | WARNING | [invalid-sizeof-comparisons.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/c/out-of-bounds/invalid-sizeof-comparisons.yaml) |

## Java Vulnerability Patterns

### 1. Path Traversal (Zip Slip) - 17 Rules

Rule file: [2-zip-slip.yml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/path-traversal/2-zip-slip.yml)

Example pattern ([L17-L21](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/path-traversal/2-zip-slip.yml#L17-L21)):

```yaml
patterns:
  - pattern: $BASE.resolve($ARG)
  - pattern-not: $BASE.resolve($ARG).normalize()
  - pattern-not: $VAR = $BASE.resolve($ARG).normalize()
```

Detects:

- `Path.resolve()` without normalization
- `File` construction without canonical path validation
- `ZipEntry` direct file writes
- `TarEntry` extraction vulnerabilities
- Missing `startsWith()` containment checks

Metadata ([L13-14](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/path-traversal/2-zip-slip.yml#L13-L14)):

```yaml
cwe: PathTraversal
vuln_type: "path-traversal"
```

### 2. Deserialization - 2 Rules

Rule file: [1.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/deserialization/1.yaml)

Pattern ([L10-L13](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/deserialization/1.yaml#L10-L13)):

```yaml
pattern-either:
  - pattern: $OBJ.readObject()
  - pattern: $OBJ.readUnshared()
  - pattern: $OBJ.readObjectOverride()
```

Detects ([L6](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/deserialization/1.yaml#L6)):

> Usage of ObjectInputStream.readObject() or similar methods can be dangerous if input is not trusted.

### 3. Jazzer Sanitizer Patterns - 1 Rule

Rule file: [search-jazzer-strings.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/special/search-jazzer-strings.yaml)

Detects hardcoded Jazzer sanitizer sentinel strings used in fuzzing hooks.

### 4. CVE-Specific Rules - 4 Rules

Targets specific CVEs from CWE Bench dataset:

- [DSpace CVE-2016-10726](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/cwe_bench/1_DSpace__DSpace_CVE-2016-10726_4.4.yml)
- [Spark CVE-2018-9159](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/cwe_bench/2_perwendel__spark_CVE-2018-9159_2.7.1.yml)
- [HAPI FHIR CVE-2023-28465](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/cwe_bench/46_hapifhir__org.hl7.fhir.core_CVE-2023-28465_5.6.105.yml)
- [Graylog CVE-2023-41044](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/java/cwe_bench/47_Graylog2__graylog2-server_CVE-2023-41044_5.1.2.yml)

These rules encode known vulnerability patterns from real-world CVEs.

## C/C++ Vulnerability Patterns

### Out-of-Bounds Write - 1 Rule

Rule file: [invalid-sizeof-comparisons.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/c/out-of-bounds/invalid-sizeof-comparisons.yaml)

Pattern ([L12-L17](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/c/out-of-bounds/invalid-sizeof-comparisons.yaml#L12-L17)):

```yaml
patterns:
  - pattern: $VAR <= sizeof($ARR)
  - pattern-not: sizeof(...) <= sizeof($ARR)
  - metavariable-regex:
      metavariable: $VAR
      regex: '^(?!.*[Ss]ize$)(?!.*[Ll]ength$)(?!.*[Ll]en$).*'
```

Detects ([L3-L6](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/c/out-of-bounds/invalid-sizeof-comparisons.yaml#L3-L6)):

> Potentially incorrect comparison using '<=' with sizeof(). Using '<=' with sizeof() can cause buffer overflows because when the value equals the array size, it's out of bounds.

CWE ([L25-L26](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/semgrep/rules/c/out-of-bounds/invalid-sizeof-comparisons.yaml#L25-L26)):

```yaml
cwe: "CWE-787: Out-of-bounds Write"
vuln_type: "out-of-bounds-write"
```

## Weight Configuration

### Severity-Based Weights

([semgrep.py L66](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/semgrep.py#L66)):

```python
sev_weights = {
    "ERROR": 10.0,
    "WARNING": 5.0,
    "INFO": 2.0
}
```

### Vulnerability-Type Weights

([semgrep.py L67-71](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/semgrep.py#L67-L71)):

```python
vuln_type_weights = {
    "jazzer": 10.0,                      # Jazzer sanitizer hooks
    "out-of-bounds-write": 9.0,          # Memory corruption
    "out-of-bounds-write-benign": 2.0,   # Lower priority OOB
    "deserialization": 4.0,              # Java deserialization
    "path-traversal": 2.5                # File system traversal
}
```

### Weight Modes

([semgrep.py L91-96](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/semgrep.py#L91-L96)):

1. **severity_only**: Uses only severity weights
   ```python
   weight = sum(sev_weights[sev] for sev in unique_severities)
   ```

2. **vuln_type**: Uses only vulnerability type weights
   ```python
   weight = sum(vuln_type_weights[vt] for vt in unique_vuln_types)
   ```

3. **combined**: Adds both severity and type weights
   ```python
   weight = severity_total + vuln_type_total
   ```

## Report Format

Input: JSON dictionary mapping function names to findings

```json
{
  "vulnerable_function": {
    "findings": [
      {
        "severity": "ERROR",
        "start_line": 42,
        "end_line": 45,
        "vuln_type": "out-of-bounds-write",
        "check_id": "semgrep.c.buffer-overflow",
        "message": "Potential buffer overflow",
        "file_path": "src/parser.c"
      }
    ]
  }
}
```
