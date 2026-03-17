# CodeQL Queries

## Overview

CodeQL performs deep semantic analysis using a query language over code databases. The CRS uses custom CodeQL queries for both C/C++ and Java targets to detect memory safety issues and injection vulnerabilities through dataflow analysis.

**Query Locations**:

- **C/C++ Queries**: [components/codeql/c_vuln_query/custom/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/codeql/c_vuln_query/custom)
- **Java Queries**: [components/codeql/qlpacks/info-extraction-java-template/](https://github.com/sslab-gatech/shellphish-afc-crs/tree/main/components/codeql/qlpacks/info-extraction-java-template)
- **Sink Methods**: [components/codeql/quickseed_query/jazzer_sink_methods.yaml](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml)

## C/C++ Queries

### Summary Table

| Query | Vulnerability Type | Weight | Detection Method | File |
|-------|-------------------|--------|------------------|------|
| uaf.ql | Use-After-Free | 5 | Dataflow from `free()` to dereference | [uaf.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/uaf.ql) |
| double_free.ql | Double Free | 5 | Multiple `free()` on same pointer | [double_free.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/double_free.ql) |
| nullptr.ql | Null Pointer Deref | 1 | General null check (REALLY noisy) | [nullptr.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/nullptr.ql) |
| nullptr.gut.ql | Null Pointer Deref | 3 | GUT variant | [nullptr.gut.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/nullptr.gut.ql) |
| nullptr.naive.ql | Null Pointer Deref | 3 | Naive detection | [nullptr.naive.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/nullptr.naive.ql) |
| alloc_const.ql | Allocation Pattern | 2 | Constant allocation analysis | [alloc_const.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/alloc_const.ql) |
| alloc_const_df.ql | Allocation Pattern | 2 | Constant allocation dataflow | [alloc_const_df.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/alloc_const_df.ql) |
| alloc_then_loop.ql | Allocation Pattern | 2 | Allocation + loop pattern | [alloc_then_loop.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/alloc_then_loop.ql) |
| alloc_checks.ql | Allocation Pattern | 2 | Allocation validation | [alloc_checks.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/alloc_checks.ql) |
| stack_buf_loop.ql | Stack Buffer | 3 | Stack buffer in loop | [stack_buf_loop.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/stack_buf_loop.ql) |
| stack_const_alloc.ql | Stack Allocation | 3 | Constant stack allocation | [stack_const_alloc.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/stack_const_alloc.ql) |

### Detailed Query Descriptions

#### 1. Use-After-Free (UAF)

Query file: [uaf.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/uaf.ql)

Detection logic ([L5-L28](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/uaf.ql#L5-L28)):

```ql
predicate isFreeFunction(Function f) { f.hasGlobalName("free") }

predicate isFreedPointer(DataFlow::Node node) {
  exists(FunctionCall call |
    isFreeFunction(call.getTarget()) and
    node.asExpr() = call.getArgument(0)
  )
}

module UafFlowConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node source) { isFreedPointer(source) }
  predicate isSink(DataFlow::Node sink) { isDeref(sink) }
}
```

Detects: Dereference of memory that may have been freed through dataflow tracking from `free()` call to pointer usage.

Weight: **5** (highest priority)

#### 2. Double Free

Query file: [double_free.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/double_free.ql)

Detects: Calling `free()` twice on the same pointer through dataflow analysis.

Weight: **5** (highest priority)

#### 3. Null Pointer Dereference - 3 Variants

Queries:

- [nullptr.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/nullptr.ql) - General null pointer detection (Weight: **1**, "REALLY noisy")
- [nullptr.gut.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/nullptr.gut.ql) - GUT variant (Weight: **3**)
- [nullptr.naive.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/nullptr.naive.ql) - Naive detection (Weight: **3**)

Detects: Dereference of potentially null pointers.

#### 4. Allocation-Related Queries - 6 Queries

All with Weight: **2-3**

- [alloc_const.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/alloc_const.ql) - Constant allocation patterns
- [alloc_const_df.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/alloc_const_df.ql) - Constant allocation dataflow
- [alloc_then_loop.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/alloc_then_loop.ql) - Allocation followed by loop
- [alloc_checks.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/alloc_checks.ql) - Allocation validation checks
- [stack_buf_loop.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/stack_buf_loop.ql) - Stack buffer in loop (Weight: **3**)
- [stack_const_alloc.ql](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/c_vuln_query/custom/stack_const_alloc.ql) - Stack constant allocation (Weight: **3**)

Detect: Suspicious allocation patterns that may lead to buffer overflows or integer overflows.

### C/C++ Vulnerability Weights

([codeql.py L97-111](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/codeql.py#L97-L111)):

```python
c_vuln_weights = {
    "nullptr": 1,              # Low weight - very noisy
    "alloc_const": 2,
    "alloc_const_df": 2,
    "alloc_then_arr": 2,
    "alloc_then_loop": 2,
    "alloc_then_mem": 2,
    "alloc_checks": 2,
    "nullptr.gut": 3,
    "nullptr.naive": 3,
    "stack_buf_loop": 3,
    "stack_const_alloc": 3,
    "double_free": 5,          # High priority
    "uaf": 5                   # High priority - use-after-free
}
```

**Focus**: Memory safety issues (allocation, null pointers, use-after-free)

**Weight Rationale** ([codeql.py L98](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/codeql.py#L98)):
- `nullptr` queries are "REALLY noisy" → low weight (1)
- `double_free` and `uaf` are critical → high weight (5)
- Allocation pattern queries → medium weight (2-3)

## Java Queries

### Summary Table

| Category | Weight | Sink Methods Count | Key Sinks | YAML Reference |
|----------|--------|-------------------|-----------|----------------|
| CommandInjection | 5 | 4 | `ProcessBuilder.start`, `Runtime.exec` | [L1-L5](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L1-L5) |
| PathTraversal | 3 | 20 | `Files.newBufferedReader`, `Path.resolve` | [L7-L27](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L7-L27) |
| ServerSideRequestForgery | 5 | 18 | `URL.openConnection`, `HttpClient.send` | [L29-L47](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L29-L47) |
| Deserialization | 5 | 4 | `ObjectInputStream.readObject` | [L49-L53](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L49-L53) |
| ExpressionLanguage | 4 | 5 | `ExpressionFactory.createValueExpression` | [L55-L60](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L55-L60) |
| LdapInjection | 4 | 2 | `DirContext.search` | [L62-L64](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L62-L64) |
| NamingContextLookup | 4 | 2 | `Context.lookup` | [L66-L68](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L66-L68) |
| ReflectionCallInjection | 4 | 8 | `Class.forName`, `ClassLoader.loadClass` | [L71-L78](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L71-L78) |
| RegexInjection | 4 | 6 | `Pattern.compile`, `String.matches` (FP-prone) | [L80-L86](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L80-L86) |
| ScriptEngineInjection | 4 | 1 | `ScriptEngine.eval` | [L88-L90](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L88-L90) |
| SqlInjection | 4 | 7 | `Statement.execute`, `Statement.executeQuery` | [L92-L99](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L92-L99) |
| XPathInjection | 4 | 3 | `XPath.evaluate`, `XPath.compile` | [L101-L104](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L101-L104) |
| XXEInjection | 5 | 4 | `DocumentBuilder.parse`, `SAXParser.parse` | [L106-L110](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L106-L110) |

**Total**: 13 categories, 86 unique sink methods monitored for taint analysis.

### Detailed Category Descriptions

#### 1. Command Injection (Weight: 5)

Sink methods ([L1-L5](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L1-L5)):

```yaml
CommandInjection:
  - java.lang.ProcessBuilder.start
  - java.lang.Runtime.exec
  - java.lang.ProcessBuilder
  - java.lang.Runtime
```

Detects: Tainted data flowing to process execution APIs.

#### 2. Path Traversal (Weight: 3)

Sink methods ([L7-L27](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L7-L27)) - 20 file operation methods:

```yaml
PathTraversal:
  - java.nio.file.Files.newBufferedReader
  - java.nio.file.Files.readAllBytes
  - java.io.FileInputStream.FileInputStream
  - java.nio.file.Path.resolve
  # ... 16 more methods
```

Detects: Unvalidated file paths in file system operations.

#### 3. Server-Side Request Forgery (Weight: 5)

Sink methods ([L29-L47](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L29-L47)) - 18 network/HTTP methods:

```yaml
ServerSideRequestForgery:
  - java.net.URL.openConnection
  - java.net.HttpURLConnection.getInputStream
  - java.net.http.HttpClient.send
  # ... 15 more methods
```

Detects: User-controlled URLs in network requests.

#### 4. Deserialization (Weight: 5)

Sink methods ([L49-L53](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L49-L53)):

```yaml
Deserialization:
  - java.io.ObjectInputStream
  - java.io.ObjectInputStream.readObject
  - java.io.ObjectInputStream.readObjectOverride
  - java.io.ObjectInputStream.readUnshared
```

Detects: Untrusted object deserialization.

#### 5. Expression Language Injection (Weight: 4)

Sink methods ([L55-L60](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L55-L60)):

```yaml
ExpressionLanguage:
  - javax.el.ExpressionFactory.createValueExpression
  - javax.el.ExpressionFactory.createMethodExpression
  - jakarta.el.ExpressionFactory.createValueExpression
  - jakarta.el.ExpressionFactory.createMethodExpression
  - javax.validation.ConstraintValidatorContext.buildConstraintViolationWithTemplate
```

Detects: Tainted data in EL expressions.

#### 6. LDAP Injection (Weight: 4)

Sink methods ([L62-L64](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L62-L64)):

```yaml
LdapInjection:
  - javax.naming.directory.DirContext.search
  - javax.naming.directory.InitialDirContext
```

#### 7. JNDI Naming Context Lookup (Weight: 4)

Sink methods ([L66-L68](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L66-L68)):

```yaml
NamingContextLookup:
  - javax.naming.Context.lookup
  - javax.naming.Context.lookupLink
```

#### 8. Reflection Call Injection (Weight: 4)

Sink methods ([L71-L78](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L71-L78)):

```yaml
ReflectionCallInjection:
  - java.lang.Class.forName
  - java.lang.ClassLoader.loadClass
  - java.lang.Runtime.load
  - java.lang.System.loadLibrary
  # ... 4 more methods
```

#### 9. Regex Injection (Weight: 4)

Sink methods ([L80-L86](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L80-L86)):

```yaml
RegexInjection:
  - java.util.regex.Pattern.compile
  - java.lang.String.matches  # Can cause many false positives
  - java.lang.String.replaceAll
  - java.lang.String.split
```

#### 10. Script Engine Injection (Weight: 4)

Sink method ([L88-L90](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L88-L90)):

```yaml
ScriptEngineInjection:
  - javax.script.ScriptEngine.eval
```

#### 11. SQL Injection (Weight: 4)

Sink methods ([L92-L99](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L92-L99)):

```yaml
SqlInjection:
  - java.sql.Statement.execute
  - java.sql.Statement.executeQuery
  - javax.persistence.EntityManager.createNativeQuery
  # ... 5 more methods
```

#### 12. XPath Injection (Weight: 4)

Sink methods ([L101-L104](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L101-L104)):

```yaml
XPathInjection:
  - javax.xml.xpath.XPath.evaluate
  - javax.xml.xpath.XPath.compile
  - javax.xml.xpath.XPath.evaluateExpression
```

#### 13. XXE Injection (Weight: 5)

Sink methods ([L106-L110](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/codeql/quickseed_query/jazzer_sink_methods.yaml#L106-L110)):

```yaml
XXEInjection:
  - javax.xml.parsers.DocumentBuilder.parse
  - javax.xml.parsers.SAXParser.parse
  - org.xml.sax.XMLReader.parse
  - javax.xml.transform.Transformer.transform
```

### Java Vulnerability Weights

([codeql.py L81-95](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/codeql.py#L81-L95)):

```python
java_vuln_weights = {
    "CommandInjection": 5,
    "Deserialization": 5,
    "PathTraversal": 3,
    "ReflectionCallInjection": 4,
    "RegexInjection": 4,
    "ServerSideRequestForgery": 5,
    "XXEInjection": 5,
    "SqlInjection": 4,
    "XPathInjection": 4,
    "ScriptEngineInjection": 4,
    "ExpressionLanguage": 4,
    "LdapInjection": 4,
    "NamingContextLookup": 4
}
```

**Focus**: Injection vulnerabilities common in Java web applications

## Report Format

Input: YAML list of functions with CodeQL hits

```yaml
- id: "func_12345"
  name: "parse_request"
  src: "src/parser.c"
  location:
    function_name: "parse_request"
    file: "src/parser.c"
    startLine: 100
    endLine: 150
  hits:
    - desc: "Potential use-after-free"
      startLine: "125"
      endLine: "125"
      type: "uaf"
      query: "use_after_free.ql"
      location: {...}
      additionalInfo: {...}
```

## Weight Calculation

**Function Matching** ([codeql.py L133-148](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/codeql.py#L133-L148)):

1. Match by function name
2. Fallback to full function name (with namespace/class)
3. Verify file path matches

**Weight Aggregation**:

```python
for match in matches:
    for hit in match.hits:
        query_name = hit.query
        vuln_weight = vuln_type_weights.get(query_name, 1.0)  # Default: 1.0
        weight += vuln_weight
```

**Metadata Collection**:
- List of unique query names that hit the function
- Stored in `metadata["codeql"]`
