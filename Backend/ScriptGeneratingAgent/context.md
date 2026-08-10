# SQL Auditing - Script Generator Agent

An automated agent that processes a SQL Server auditing checklist and generates evaluation scripts (SQL/PowerShell) using a Small Language Model (SLM). No SQL Server connection is required — the agent focuses purely on script generation.

## Architecture

```
master-checklist.json
        │
        ▼
   Program.cs (Entry Point)
        │
        ▼
   ScriptGeneratorAgent.RunAsync()
        │
        ▼
   For each checklist item:
        │
        ▼
   ChecklistItemProcessor.GenerateScriptAsync(item)
        │
        ├── Single LLM call determines:
        │     • FEASIBLE? (YES/NO)
        │     • SCOPE (SERVER/DATABASE)
        │     • SCRIPT_TYPE (sql/ps1)
        │     • Script content with Pass/Fail + Score (0-3)
        │
        ├── NOT FEASIBLE → Log reason → Write to results
        │
        └── FEASIBLE
              │
              ▼
        ScriptOutputValidator.Validate()
              │
              ├── INVALID → Log error → Write to results
              │
              └── VALID → Save script → Write to results
```

## Project Structure

```
agents/
├── config/
│   └── appsettings.json              # LLM configuration (URL, API key, model, timeout)
│
├── models/
│   ├── ChecklistItem.cs              # Input checklist item model
│   ├── ExecutionResultEntry.cs       # Per-item result record
│   ├── ScriptGenerationResponse.cs   # LLM parsed response
│   └── ScriptMapping.cs             # Checklist → script mapping
│
├── modules/
│   ├── ChecklistItemProcessor.cs     # LLM call: feasibility + scope + script generation
│   ├── ScriptGeneratorAgent.cs       # Orchestrator: loop → LLM → validate → save
│   └── ScriptOutputValidator.cs      # Validates script has Result + Score output
│
├── prompts/
│   ├── script_generator_system.txt   # System prompt (rules + scoring + examples)
│   └── script_generator_user.txt     # Per-item user prompt template
│
├── agents.csproj
├── Program.cs                        # Entry point
└── README.md

checklist/
├── master-checklist.json             # Input: all checklist items
├── deterministic-script-mapping.json # Output: checklist → script mapping
└── scripts/
    ├── sql/                          # Generated SQL scripts
    └── ps1/                          # Generated PowerShell scripts

results/
└── execution-results.json            # Output: per-item status (iteratively updated)
```

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download) (or compatible version)
- Access to an LLM endpoint (default: `https://llm.maqsoftware.net/v1`)

## Configuration

Edit `config/appsettings.json`:

```json
{
  "LLM": {
    "BaseUrl": "https://llm.maqsoftware.net/v1",
    "ApiKey": "your-api-key",
    "Model": "qwen-3.6-27b",
    "TimeoutSeconds": 300,
    "MaxRetries": 3
  }
}
```

| Setting          | Description                                | Default |
|------------------|--------------------------------------------|---------|
| `BaseUrl`        | LLM API endpoint (OpenAI-compatible)       | —       |
| `ApiKey`         | API key for authentication                 | —       |
| `Model`          | Model name                                 | —       |
| `TimeoutSeconds` | HTTP timeout per LLM call                  | 300     |
| `MaxRetries`     | Retry count on timeout/server errors       | 3       |

## Usage

### Build

```bash
cd Backend/agents
dotnet build
```

### Run

```bash
dotnet run -- ..
```

`args[0]` is the path to the `Backend` root folder. If omitted, defaults to the parent of the current directory.

### Example Output

```
==============================================
 SQL Auditing - Script Generator Agent
 Checklist → LLM → SQL/PS1 Scripts
==============================================

[Agent] Loaded 45 checklist items

[Agent] 1.1.1 - Deployment model is deliberate and documented
 Generating script via LLM...
 ✓ Script saved: sql/DeploymentModelDocumentationCheck.sql
   Scope: SERVER
   Scoring: 0=No metadata found; 1=Detected but no rationale; 2=Extended properties exist

[Agent] 1.1.5 - Architecture diagram exists and reflects the actual implementation
 Generating script via LLM...
 NOT FEASIBLE: Requires reviewing external documentation and manual comparison

============== SUMMARY ==============
Generated : 38
Skipped   : 5
Failed    : 2

Results:
Backend/results/execution-results.json
```

## Scoring System

Every generated script returns two fields:

| Field    | Type   | Description                          |
|----------|--------|--------------------------------------|
| `Result` | string | `Pass` or `Fail`                     |
| `Score`  | int    | `0` to `3` indicating compliance     |

### Score Breakdown

| Score | Meaning       | Description                                    |
|-------|---------------|------------------------------------------------|
| 0     | Fail          | Not configured or completely non-compliant     |
| 1     | Partial Pass  | Minimal evidence exists but largely incomplete |
| 2     | Mostly Pass   | Good evidence/configuration with minor gaps    |
| 3     | Pass          | Fully compliant                                |

> **Note:** For checks that provide partial automated evidence (requiring human review for full compliance), the maximum score is capped at **2**.

## Generated Script Format

### SQL Script

```sql
-- Checklist: Schema separation used to organize layers/domains
-- Scoring: 0=All tables in dbo; 1=Few non-dbo schemas; 2=Multiple schemas; 3=Well-organized
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

-- ... evaluation logic using sys catalog views ...

SELECT @Result AS Result, @Score AS Score;
```

### PowerShell Script

```powershell
# Checklist: Windows authentication mode check
# Scoring: 0=SQL auth only; 3=Windows/integrated auth enabled
$Score = 0
$Result = "Fail"

# ... evaluation logic ...

[PSCustomObject]@{ Result = $Result; Score = $Score }
```

## Output Files

### `results/execution-results.json`

Updated **iteratively** after each checklist item is processed. Safe to read while the agent is running.

```json
{
  "generatedAt": "2026-08-07T10:30:00Z",
  "totalProcessed": 15,
  "results": [
    {
      "checklistId": "1.1.1",
      "checkName": "Deployment model is deliberate and documented",
      "category": "Architecture Design",
      "scope": "SERVER",
      "status": "Script Generated",
      "scriptType": "sql",
      "scriptPath": "sql/DeploymentModelDocumentationCheck.sql",
      "scoringLogic": "0=No metadata; 1=Detected; 2=Properties exist"
    },
    {
      "checklistId": "1.1.5",
      "checkName": "Architecture diagram exists",
      "status": "Not Feasible",
      "reason": "Requires external documentation review"
    }
  ]
}
```

### `checklist/deterministic-script-mapping.json`

Maps each checklist item to its generated script.

```json
{
  "mappings": [
    {
      "checklistId": "1.1.1",
      "name": "Deployment model is deliberate and documented",
      "scope": "SERVER",
      "scriptType": "sql",
      "scriptPath": "sql/DeploymentModelDocumentationCheck.sql",
      "maxScore": 3,
      "scoringLogic": "0=No metadata; 1=Detected; 2=Properties exist"
    }
  ]
}
```

## Retry & Error Handling

- **LLM timeout** (`TaskCanceledException`): Retries with exponential backoff (3s, 6s, 9s)
- **Server errors** (524, 502, etc.): Retries with same backoff strategy
- **All retries exhausted**: Item marked as `Failed` in results, agent continues to next item
- **Iterative saving**: Results are written to disk after every item, so progress is preserved even if the agent crashes

## Feasibility Rules

The agent generates scripts for any check where SQL/PowerShell can provide **full or partial evidence**:

| Generates Script ✓                              | Skips ✗                                      |
|--------------------------------------------------|----------------------------------------------|
| Schema naming patterns (sys.schemas)             | "Are DBAs trained?"                          |
| Duplicate table detection (sys.tables)           | Physical/environmental inspection            |
| Metadata column presence (sys.columns)           | External system access outside SQL Server    |
| Configuration values (sys.configurations)        | Document existence verification              |
| Permission checks (sys.database_permissions)     | Process/policy adherence                     |
| Object reuse patterns (sys.sql_expression_dependencies) | Architecture diagram review           |