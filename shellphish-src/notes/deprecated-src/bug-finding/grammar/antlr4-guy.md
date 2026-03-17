# ANTLR4-Guy

ANTLR4-Guy performs diff-based vulnerability ranking by comparing function diffs with known CVE patches to prioritize security-relevant code changes.

## Purpose

- Diff-based vulnerability ranking
- Compare function changes with known CVE patches
- Prioritize security-relevant code changes
- Help focus analysis on high-risk modifications

## CRS-Specific Usage

**Integration**:
- Analyzes function diffs from clang-indexer
- Retrieves known vulnerability patches from database
- Ranks modified functions by similarity to CVEs

**Workflow**:
1. Extract function diffs (commit vs base)
2. Query retrieval API for similar vulnerability patches
3. Compute similarity scores
4. Rank functions by security relevance
5. Prioritize high-scoring functions for analysis

**Use Cases**:
- **Patch Validation**: Check if fix resembles known CVE patches
- **Regression Detection**: Identify changes similar to past vulnerabilities
- **Risk Assessment**: Score code changes by vulnerability likelihood

**Output**: Ranked list of potentially vulnerable functions

## Related Components

- **[Clang Indexer](../static-analysis/clang-indexer.md)**: Provides function diffs
- **[Grammar-Guy](./grammar-guy.md)**: Can use rankings for targeted grammar generation
