# SQL Auditing — Script Generator Agent

## 1. Overview

The **SQL Auditing Script Generator Agent** is a .NET-based automation tool that generates and executes audit scripts for Azure SQL / SQL Server environments.

The agent is designed around a checklist-driven auditing workflow:

1. Load audit checklist items.
2. Connect to the target SQL Server.
3. Discover server and database context.
4. Send each checklist item and environment context to an LLM.
5. Generate a deterministic audit script.
6. Determine whether the checklist item is programmatically feasible.
7. Validate the generated script.
8. Execute the script against the appropriate SQL scope.
9. Collect `Result` and `Score`.
10. Save generated scripts and audit results.

The project is designed primarily for **read-only security and configuration auditing**.

---

# 2. Project Goals

The main goals of the agent are:

- Automate SQL security auditing.
- Reduce manual audit-script development.
- Convert natural-language checklist requirements into executable scripts.
- Support server-level and database-level checks.
- Use live SQL Server metadata when generating scripts.
- Standardize audit results using a 0–3 scoring system.
- Identify checks that cannot be evaluated automatically.
- Preserve generated scripts as reusable audit artifacts.
- Produce machine-readable execution results.

---

# 3. High-Level Architecture

```text
                         ┌──────────────────────┐
                         │      Program.cs      │
                         │     Entry Point      │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │ ScriptGeneratorAgent │
                         │    Orchestrator      │
                         └──────────┬───────────┘
                                    │
             ┌──────────────────────┼──────────────────────┐
             │                      │                      │
             ▼                      ▼                      ▼
   ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
   │ SqlConnection    │   │ ChecklistItem    │   │ ScriptOutput     │
   │ Manager          │   │ Processor        │   │ Validator        │
   └────────┬─────────┘   └────────┬─────────┘   └────────┬─────────┘
            │                      │                      │
            ▼                      ▼                      │
       Azure SQL                  LLM                     │
                                   │                      │
                                   ▼                      │
                         ScriptGenerationResponse        │
                                                          │
                                                          ▼
                                               ┌──────────────────┐
                                               │ ScriptExecutor   │
                                               └────────┬─────────┘
                                                        │
                                                        ▼
                                               Azure SQL / pwsh
                                                        │
                                                        ▼
                                               ScriptExecutionResult
                                                        │
                                                        ▼
                                               Results / Mapping

---

# 4. Runtime Flow

Program.cs
    │
    ▼
Load appsettings.json
    │
    ├── SQL Server connection string
    └── LLM configuration
    │
    ▼
Create application components
    │
    ▼
ScriptGeneratorAgent.RunAsync()
    │
    ▼
Connect to SQL Server
    │
    ▼
Discover SQL Server context
    │
    ├── SQL version
    ├── SQL edition
    ├── Server permissions
    ├── Features
    └── Databases
    │
    ▼
Load master-checklist.json
    │
    ▼
Process each checklist item
    │
    ▼
Build LLM prompt
    │
    ▼
Call LLM
    │
    ▼
Parse LLM response
    │
    ├── FEASIBLE: NO
    │       │
    │       └── Add to skipped results
    │
    └── FEASIBLE: YES
            │
            ▼
       Validate script
            │
            ├── Invalid → Failed
            │
            └── Valid
                  │
                  ▼
             Execute script
                  │
                  ▼
           Collect Result + Score
                  │
                  ▼
           Save generated script
                  │
                  ▼
       Add result to execution report
    │
    ▼
Write deterministic-script-mapping.json
    │
    ▼
Write execution-results.json
    │
    ▼
Print execution summary



---

# 5. Directory Structure

SCRIPTGENERATINGAGENT/
│
├── agents/
│   │
│   ├── bin/
│   │
│   ├── config/
│   │   ├── appsettings.json
│   │   └── scoring-rules.json
│   │
│   ├── models/
│   │   ├── ChecklistItem.cs
│   │   ├── DatabaseContext.cs
│   │   ├── ExecutionResultEntry.cs
│   │   ├── ScriptExecutionResult.cs
│   │   ├── ScriptGenerationResponse.cs
│   │   ├── ScriptMapping.cs
│   │   └── SqlServerContext.cs
│   │
│   ├── modules/
│   │   ├── ChecklistItemProcessor.cs
│   │   ├── ScriptExecutor.cs
│   │   ├── ScriptGeneratorAgent.cs
│   │   ├── ScriptOutputValidator.cs
│   │   └── SqlConnectionManager.cs
│   │
│   ├── prompts/
│   │   ├── script_generator_system.txt
│   │   └── script_generator_user.txt
│   │
│   ├── agents.csproj
│   └── Program.cs
│
├── checklist/
│   ├── scripts/
│   │   ├── ps1/
│   │   └── sql/
│   │
│   ├── deterministic-script-mapping.json
│   └── master-checklist.json
│
├── results/
│   └── execution-results.json
│
├── readme.md
├── context.md
└── newContext.md


