# SQL Auditing Tool - High Level Architecture

## Purpose

The SQL Auditing Tool evaluates SQL environment compliance against a checklist using three techniques:

- Script: deterministic SQL scripts from mapping.
- AI-MCP: AI evaluation using SQL metadata snapshot and model prompts.
- AI-Manual: manual operator validation with AI-generated instructions.

Primary outputs are grouped by audit run under
`results/<yyyyMMdd_HHmmss_fff>_<sanitized-server-name>/`:

- `checklist_results.json`
- `historical_last_run.json`
- `final_report.md`
- `progress_stream.txt`
- `ui_log.txt`

## Architectural Overview

```mermaid
graph LR
    U["Auditor or Operator"]

    subgraph UI["Frontend - WPF"]
      MW["MainWindow<br/>Login -> Checklist -> Evaluate -> Summary"]
    end

    subgraph CORE["Backend Core"]
      AUD["Auditor.cs<br/>Orchestration Engine"]
      DEC["EvaluationDecisionService<br/>Outcome Rules"]
    end

    subgraph AGENTS["Backend Agents"]
      MCP["SqlServerMcpEvaluator<br/>SQL Snapshot + LLM Decision"]
      MSG["ManualStepsGenerator<br/>LLM Manual Steps"]
      PTS["PromptTemplateStore<br/>Prompt Loading and Rendering"]
    end

    subgraph DATA["Configuration and Assets"]
      CHK["master-checklist.json"]
      MAP["deterministic-script-mapping.json"]
      SQLS["Backend/checklist/scripts/sql"]
      PR["Backend/agents/prompts"]
    end

    subgraph EXT["External Systems"]
      DB["SQL Server"]
      LLM["Model Provider API"]
    end

    subgraph OUT["Output Artifacts"]
      RES["results"]
    end

    U --> MW
    MW --> AUD
    AUD --> CHK
    AUD --> MAP
    AUD --> SQLS
    AUD --> DEC
    AUD --> MCP
    AUD --> MSG
    MCP --> PTS
    MSG --> PTS
    PTS --> PR
    AUD --> DB
    MCP --> DB
    MCP --> LLM
    MSG --> LLM
    AUD --> RES
    MW --> RES
```

## Runtime Flow (End-to-End)

```mermaid
graph TD
  A["Start App"] --> B["Verify Access<br/>Build connection string from auth mode"]
  B --> C{"Connection valid?"}
  C -- "No" --> C1["Stay on Login<br/>Show failure status"]
  C -- "Yes" --> D["Load checklist structure"]
  D --> E["Load deterministic mapping"]
  E --> F["Classify selected items<br/>Script mapped vs AI items"]

  F --> G["Run Script Pipeline"]
  F --> H["Run AI Pipeline"]

  G --> G1["Execute mapped SQL files"]
  G1 --> G2["Derive outcome from script evidence"]

  H --> H1{"SQL connection available?"}
  H1 -- "Yes" --> H2["Try AI-MCP evaluation"]
  H2 --> H3{"MCP feasible and parsed?"}
  H3 -- "Yes" --> H4["Store AI-MCP result"]
  H3 -- "No" --> H5["Queue AI-Manual"]
  H1 -- "No" --> H5

  H5 --> H6["Generate manual instructions"]
  H6 --> H7["Collect operator PASS or FAIL evidence"]
  H7 --> H8["Store AI-Manual result"]

  H5 -- "Reuse enabled and historical result exists" --> H9["Copy result from historical_last_run.json"]

  G2 --> I["Merge all results"]
  H4 --> I
  H8 --> I
  H9 --> I

  I --> J["Write checklist_results.json"]
  J --> K["On request: refresh historical_last_run.json, build final_report.md + audit_report.xlsx"]
  K --> L["Display Summary tab"]
```

## Evaluation Decision Logic

1. Script technique
- Used when checklist item has mapped script(s).
- Executes SQL and captures textual evidence.
- Outcome derived using evidence heuristics (`Pass`, `Fail`, `NeedsReview`).

2. AI-MCP technique
- Used for unmapped items when SQL connectivity is available.
- Builds SQL snapshot (server metadata + user DB summaries).
- Sends prompt to model provider and parses structured response.
- If response is feasible and parseable, uses AI-MCP result.

3. AI-Manual technique
- Fallback when MCP is unavailable, infeasible, or when no SQL connection.
- Generates manual verification steps (LLM first, static prompt fallback).
- Operator provides PASS/FAIL or notes; result is persisted.

## Main Modules and Responsibilities

- `Backend/core/Auditor.cs`
  - Core orchestrator for checklist loading, pipeline execution, and result persistence.
  - Normalizes SQL connection variants and coordinates Script/AI flows.

- `Backend/agents/modules/SqlServerMcpEvaluator.cs`
  - Collects SQL snapshot and performs model-based evaluation for AI-MCP.
  - Handles provider call, response parsing, and feasibility checks.

- `Backend/agents/modules/ManualStepsGenerator.cs`
  - Generates actionable manual validation steps for AI-Manual workflow.

- `Backend/agents/modules/EvaluationDecisionService.cs`
  - Applies deterministic outcome rules over evidence.

- `Backend/agents/modules/PromptTemplateStore.cs`
  - Resolves and renders prompt templates from `Backend/agents/prompts/`.

- `Backend/agents/modules/application/HistoricalManualResultsStore.cs`
  - Reads/writes `results/historical_last_run.json` (manual and AI-Manual results keyed by
    checklist ID) so completed manual evaluations can be reused by a later run.
  - Refreshed only at report generation; shared by WPF, CLI and IDE/MCP.

- `Frontend/MainWindow/MainWindow.xaml(.cs)`
  - Implements staged UX and user-driven evaluation lifecycle.
  - Handles checklist selection, manual evidence capture, and summary rendering.

## Data and File Boundaries

- Checklist definition: `Backend/checklist/master-checklist.json`.
- Deterministic mapping: `Backend/checklist/deterministic-script-mapping.json`.
- SQL script assets: `Backend/checklist/scripts/sql/`.
- Prompt templates: `Backend/agents/prompts/`.
- Runtime artifacts: `results/`.

## Deployment/Execution Modes

- Console mode (`Backend/core/Program.cs`): interactive CLI for script and checklist evaluation.
- Desktop mode (`Frontend/MainWindow/SQLAuditor.Wpf.csproj`): guided, staged execution with manual queue and summary UX.
