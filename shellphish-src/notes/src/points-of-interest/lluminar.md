# LLuMinar (ScanGuy) - LLM-Based Vulnerability Scanner ⚠️ DISABLED

## Overview

> **Status**: ⚠️ **DISABLED** - LLuMinar is fully implemented but **not enabled** in the competition pipeline. Integration with CodeSwipe is commented out in [preprocessing.yaml#L330](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/pipelines/preprocessing.yaml#L330).

LLuMinar is an LLM-based vulnerability scanning agent that was designed for dual roles in the CRS:

1. **Points of Interest (POI)**: Identifies potentially vulnerable functions for prioritization
2. **Vulnerability Identification**: Generates proof-of-concept (PoC) exploits for discovered vulnerabilities

## Role in Points of Interest (DISABLED)

Within the POI subsystem, LLuMinar was designed to operate as a **filter** in the Code-Swipe framework via the **ScanGuy** component, but this integration is currently disabled.

**Integration**: [components/code-swipe/src/filters/scanguy.py](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/components/code-swipe/src/filters/scanguy.py)

### How It Would Work (If Enabled)

1. **Input**: All functions reachable from harness entry points
2. **Analysis**: Fine-tuned LLM (Qwen2.5-7B-Instruct) predicts vulnerability status
3. **Output**: `scan_results.json` with predictions:

   ```json
   {
     "function_index_key": "file.c:func:123",
     "predicted_is_vulnerable": "yes",
     "predicted_vulnerability_type": "CWE-416",
     "output": "Reasoning about why function is vulnerable..."
   }
   ```

4. **Weight Assignment**: Functions predicted as vulnerable would receive configured weight in CodeSwipe ranking

### Key Characteristics

- **Lightweight**: Maximum 5 tool invocations per function for speed
- **Context-Aware**: Samples 3 random call graph paths for context
- **Semantic Understanding**: Goes beyond pattern matching to understand code logic

### Model Training

Fine-tuned on ARVO dataset with:

1. Vulnerable/patched function pairs
2. Benign functions
3. Proof-of-concept generation data
4. Agent-based interaction trajectories

## Detailed Implementation

For comprehensive implementation details, model architecture, training methodology, and vulnerability identification capabilities, see:

**[LLuMinar - Vulnerability Identification](../vulnerability-identification/LLuMinar.md)**

That section covers:

- Agent scaffold design (HongweiScan + HongweiValidate)
- Model fine-tuning process
- Context retrieval mechanisms
- Two-phase analysis workflow
- Integration with Discovery Guy
- Why it's disabled in competition

## References

From whitepaper [Section 5](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/notes/src/whitepaper/Artiphishell-3.md#5-points-of-interests):
> In addition, there is an agent called LLuMinar, which uses our fine-tuned LLM to retrieve context and identify potentially vulnerable functions.

From whitepaper [Section 6.5](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/notes/src/whitepaper/Artiphishell-3.md#65-lluminar):
> The LLuMinar agent scans all functions and methods reachable from any harness entry point, using our customized reasoning model to autonomously retrieve relevant context and determine whether a function is vulnerable.
