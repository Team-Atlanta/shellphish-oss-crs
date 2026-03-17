# DyVA

> From whitepaper [Section 7.2](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/notes/src/whitepaper/Artiphishell-3.md#72-dyva):
>
> Dyva is an LLM agent designed to identify the root cause of software vulnerabilities. For Dyva, we define the root cause as the precise location in source code and the specific program state conditions that leads to the vulnerable behavior.
>
> To begin analysis, Dyva takes three primary inputs. 1 A stack trace from the program crash or sanitizer report. 2 The vulnerability type. 3 A crashing seed, which is the specific input that triggers the vulnerability. Dyva uses an agentic approach, leveraging a set of tools to systematically investigate the bug. This approach allows it to dynamically formulate and execute an analysis plan based on the information it gathers. The tools available to Dyva include:
>
> - **Static Code Analysis**: Dyva has access to the program's indexed source code, enabling it to: 1 Retrieve specific lines of code for inspection. 2 Fetch the complete definition of any function.
> - **Dynamic Code Analysis**: Dyva can interact with a debugger to observe the program's runtime behavior. It supports GDB for C/C++ and JDB for Java. The debugging capabilities are twofold: 1 State Inspection: Setting breakpoints at specific lines of code to examine the program state, including local variables, memory layout, and register values at that exact moment. 2 State Differentiation: Calculating the "delta" or change in program state between two execution points (e.g., between two lines of code). This allows Dyva to track how variables and registers are modified, isolating the operations that lead to the vulnerable state.
>
> This combination of static and dynamic analysis tools enables Dyva to correlate runtime errors with specific source code constructs, performing a comprehensive analysis to pinpoint the vulnerability's origin.
>
> The output of Dyva is a root cause report, containing a structured explanation of the vulnerability. This report includes a natural language description of the bug, the relevant code locations, dataflow leading to the crash, bug class, and candidate patches.
