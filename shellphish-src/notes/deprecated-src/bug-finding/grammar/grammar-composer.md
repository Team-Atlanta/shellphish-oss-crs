# Grammar-Composer

Grammar-Composer combines grammar fragments from multiple sources into unified Nautilus grammars. It manages grammar fingerprints, rule hashes, and RON format conversion.

## Purpose

- Merge grammar fragments from multiple generators
- Create RON (Rusty Object Notation) format for Nautilus
- Manage grammar fingerprints and rule hashes
- Resolve conflicts between grammar sources

## CRS-Specific Features

**Integration Points**:
- Consumes grammars from Grammar-Guy
- Merges with hand-written grammar fragments
- Outputs to AFL++/Jazzer

**Key Operations**:
- **Fragment Merging**: Combines multiple grammar sources
- **Conflict Resolution**: Handles overlapping rules
- **Deduplication**: Removes redundant productions
- **Format Conversion**: Ensures Nautilus compatibility

**Output**: Unified RON grammars for fuzzers

## Related Components

- **[Grammar-Guy](./grammar-guy.md)**: Grammar source
- **[Grammaroomba](./grammaroomba.md)**: Post-processing optimization
