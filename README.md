# SQL Auditor

Desktop application that audits a SQL Server instance against a governance checklist. Controls are evaluated three ways: deterministic T-SQL scripts, AI-assisted evaluation against a live connection, and AI-generated manual verification steps for controls that cannot be checked automatically.

High-level architecture and flow documentation: see `ARCHITECTURE.md`.

## Prerequisites

| Requirement | Version | Notes |
| --- | --- | --- |
| Windows | 10 or later | The UI is WPF; it does not run on Linux or macOS |
| .NET SDK | 8.0 or later | Projects target `net8.0`; the WPF app targets `net8.0-windows` |
| .NET Desktop Runtime | 8.0 or later | Ships with the SDK |
| SQL Server | 2016 or later | Local or remote; SQL Server Express is fine |
| Git | any recent version | To clone the repository |

You will also need:

- A Windows account or SQL login on the target instance with at least `VIEW SERVER STATE`.
- An OpenAI-compatible LLM endpoint and API key **for the desktop app only**, which asks for
  them at runtime — no config file is required. The CLI and the MCP server use GitHub Copilot
  as their AI instead and need no provider settings at all
  (see [LLM provider settings](#2-llm-provider-settings)).

Confirm your toolchain before starting:

```powershell
dotnet --version
dotnet --list-runtimes | Select-String "WindowsDesktop"
```

## Installation

### 1. Clone the repository

```powershell
git clone https://github.com/AkashReddy-3084/SQL-Auditing-tool.git
cd SQL-Auditing-tool
```

### 2. LLM provider settings

The repository ships **no `.env`** and none is needed. Who acts as the AI depends on the host:

| Host | AI | Configuration |
| --- | --- | --- |
| Desktop app (WPF) | Your OpenAI-compatible endpoint | Base URL, API Key and Model entered on the LLM panel at runtime; held in memory for the session only |
| CLI | GitHub Copilot CLI | None — the binary makes no LLM calls |
| MCP server (VS Code) | GitHub Copilot Chat, via MCP sampling | None — nothing sensitive belongs in `.vscode/mcp.json` |

If you do want the desktop app to pick its settings up automatically, it also honours
`PROVIDER_BASE_URL`, `PROVIDER_API_KEY`, `MODEL` and `PROVIDER_TIMEOUT_SECONDS` from the
environment or from a git-ignored `.env` at the repository root. Nothing in the repo requires
it.

### 3. Restore dependencies

```powershell
dotnet restore Frontend/MainWindow/SQLAuditor.Wpf.csproj
```

### 4. Build

```powershell
dotnet build Frontend/MainWindow/SQLAuditor.Wpf.csproj
```

### 5. Run

```powershell
dotnet run --project Frontend/MainWindow/SQLAuditor.Wpf.csproj
```

## Using the application

1. **Login** — enter the SQL Server FQDN, choose Windows Authentication or SQL Login, and click *Verify Access*. Named instances such as `localhost\SQLEXPRESS` are supported. After verification, choose one or more accessible user databases from the database dropdown, or choose *All Databases*. Nothing is selected by default.
2. **LLM access** — enter the Base URL, API Key and Model for your OpenAI-compatible endpoint and click *Verify LLM access*.
3. **Checklist** — select the controls to evaluate.
4. **Evaluate** — script and AI checks run in parallel. Controls needing human judgement appear with generated verification steps for you to mark Pass or Fail.
5. **Generate Scripts** — runs the script-generation pipeline for the selected controls and writes them to `Backend/checklists/Scripts/`.
6. **Summary** — generates the scored report and lets you export it.
7. **Export Manual CSV + Generate** — after evaluation finishes, exports every selected manual check and its verification guidance to CSV. Unanswered manual checks are recorded as **Skipped**, excluded from all scores, and retained in the generated Markdown and Excel reports for audit transparency. Submitted and previously copied manual decisions are preserved.

### Reuse a filled manual-check CSV

1. In the exported CSV, enter `Pass` or `Fail` in **Decision** and the observation supporting that decision in **Evidence**. Keep the header row and **Checklist ID** values unchanged.
2. Start the next evaluation with the checklist IDs represented in the CSV and wait for the automated evaluation to finish.
3. On the **Evaluate** tab, select **Import Filled Manual CSV** and choose the completed file.
4. The importer applies valid rows only to pending manual checks in the current run. Blank decisions or evidence, invalid decisions, duplicate IDs, IDs not selected in the run, non-manual checks, and checks already completed in the run are reported and left unchanged.
5. Resolve any remaining pending rows, then select **Generate Summary / Report**.

The accepted decision values are `Pass`, `Passed`, `P`, `Fail`, `Failed`, and `F` (case-insensitive). The import can also be performed in the same run after the CSV has been completed externally.

Database-scoped scripts never embed the login-page selection. A generated `DATABASE` script
checks only its current connection database and reports `DB_NAME()`; the backend opens that same
reusable script once for each selected database and combines the returned rows with the existing
worst-score rule. Server-scoped and system-database checks continue to run through the master
connection. CLI and IDE evaluations, which have no desktop selector, default to all accessible
online user databases.

## Command-line interface (CLI)

The same evaluation engine is available as a console command for automation and CI. It
reuses the checklist, scoring, and report generation. The CLI makes **no LLM/API calls**
and needs **no `.env` / `PROVIDER_BASE_URL` / `PROVIDER_API_KEY` / `MODEL`**. Controls that
need human judgement come back as **Needs Review** for a person — or GitHub Copilot CLI — to
decide, and `generate_scripts` hands the standard generator prompt to Copilot CLI in the same
spirit.

### Build

```powershell
dotnet build Backend/CLI/SQLAuditor.csproj
```

This produces `Backend/CLI/bin/Debug/net8.0/SQLAuditor.exe`.

### Run an evaluation

```powershell
Backend\CLI\bin\Debug\net8.0\SQLAuditor.exe evaluate [options]
```

Any option not supplied is prompted for interactively (SQL Server, then login details, then
checklist IDs).

| Option | Description |
| --- | --- |
| `--items <ids>` | Comma-separated checklist IDs to evaluate, e.g. `1.1.2,3.1.2` |
| `--server <host>` | SQL Server FQDN / `host[,port]`. Or set `SQLAUDITOR_SERVER` |
| `--user <name>` | SQL login username. Or set `SQLAUDITOR_SQL_USER`. Omit for Windows Integrated auth |
| `--password <pw>` | SQL login password. Or set `SQLAUDITOR_SQL_PASSWORD` |
| `--json <path>` | Also copy the results JSON to this path |
| `--interactive` | Force prompting to mark manual-review items Pass/Fail (auto-enabled in an interactive terminal) |
| `--copilot` | Non-interactive; emit `Needs Review` items in a `COPILOT REVIEW REQUIRED` block for the GitHub Copilot CLI skill to review and decide via `resolve_review` |
| `--help` | Show usage |

Related subcommands: `resolve_review --id <id> --decision <pass\|fail\|needsreview> [--notes <text>]`
records a decision for a `Needs Review` item and regenerates the report;
`enrich_result --id <id> [--finding <text>] [--evidence <text>] [--risk <text>] [--recommendation <text>]`
records the audit wording for a script-evaluated item (its Outcome, Score, Severity and
Databases Verified stay script-derived); `generate_scripts --items <ids>` runs the script
generation pipeline (see below); `show_reports [--kind json]`
prints the latest report; `--dump-checklist` lists the checklist structure.

Examples:

```powershell
# Fully interactive (prompts for the manual-results source, server, auth, and items)
Backend\CLI\bin\Debug\net8.0\SQLAuditor.exe evaluate

# Non-interactive with flags
Backend\CLI\bin\Debug\net8.0\SQLAuditor.exe evaluate --items 1.1.2,3.1.2 --server localhost --manual-results fresh

# Reuse the manual results recorded by the previous audit
Backend\CLI\bin\Debug\net8.0\SQLAuditor.exe evaluate --items 1.1.2,3.1.2 --server localhost --manual-results last-runs

# Copilot CLI mode: surface Needs Review items for Copilot to review
Backend\CLI\bin\Debug\net8.0\SQLAuditor.exe evaluate --copilot --items 1.1.2,3.1.2 --server localhost --manual-results fresh

# Render the reports once the evaluation is complete
Backend\CLI\bin\Debug\net8.0\SQLAuditor.exe generate_report

# List the checklist structure without running an evaluation
Backend\CLI\bin\Debug\net8.0\SQLAuditor.exe --dump-checklist
```

### Manual review and output

Every run starts by asking how manual checklist items should be handled: **use the last runs**
(copy the results recorded in the latest run's `historical_last_run.json` and skip their manual review) or
**fresh evaluation**. Script-based controls are decided automatically. Controls needing human
judgement come back as **Needs Review**; in an interactive terminal (or with `--interactive`) the
CLI shows the verification guidance and prompts you to mark each **Pass**, **Fail**, or **Skip**
(with optional notes). Results are written to the server-specific run directory described in
[Output](#output).

The report is **not** generated automatically. The CLI asks *"Evaluation completed. Do you want to
generate the summary/report?"*; answering yes (or running `generate_report` later) refreshes
`historical_last_run.json` with the newly evaluated manual results and writes `final_report.md`
and `audit_report.xlsx` in that same run directory.

The command returns an exit code for scripting: `0` success, `1` one or more controls
failed, `2` usage/validation error, `3` unexpected error.

### Generate audit scripts

```powershell
Backend\CLI\bin\Debug\net8.0\SQLAuditor.exe generate_scripts --items 1.1.2,3.1.1
Backend\CLI\bin\Debug\net8.0\SQLAuditor.exe save_generated_script --id 3.1.1 --response-file <raw response> [--validation-file <verdict>]
```

This is **generation, not evaluation**: no SQL Server, no credentials, no LLM settings.
`generate_scripts` prints the generator system prompt from `Backend/Modules/generate_scripts/prompts/` plus one
filled request per item; Copilot CLI (or you) answers it, and `save_generated_script` runs the
rest of the pipeline — the deterministic format gate, the C1-C7 validation prompt, the verdict
and any corrected script — before writing to `Backend/checklists/Scripts/{sql,ps1}/` and
updating `Backend/checklists/deterministic-script-mapping.json` and
`Backend/results/execution-results.json`. Without `--validation-file` the save command prints
the validation prompt and saves nothing.

The mapping records each generated script's `scope`. `SERVER` scripts use instance/system
catalogs; `DATABASE` scripts inspect only the current database. Database names are supplied only
at evaluation time by the backend connection configuration, so generated scripts can be reused
with a different database selection.

## GitHub Copilot CLI integration (skill)

The auditor can be driven from **GitHub Copilot CLI** using the `sql-auditor` skill in
`.github/skills/sql-auditor/`. In this mode **Copilot CLI itself is the AI layer** — signed
in with the same GitHub Copilot account used by `/login`. The `SQLAuditor` CLI runs the
engine, the validation gates and the persistence steps only, and makes **no LLM/API calls**;
**no `.env` / `PROVIDER_BASE_URL` / `PROVIDER_API_KEY` / `MODEL`** is used or requested.

Workflow:

1. `/login` to GitHub Copilot CLI, then invoke the `sql-auditor` skill's `evaluate` command
   (it runs `SQLAuditor.exe evaluate --copilot`).
2. The CLI asks for the **SQL Server** and **authentication** (Windows Integrated, or SQL
   Login via `--user` with the password in the `SQLAUDITOR_SQL_PASSWORD` session environment
   variable — never typed in chat), then evaluates the requested checklist items.
3. Script-based controls are decided deterministically. **Needs Review** items are emitted in
   a `COPILOT REVIEW REQUIRED` block.
4. For each item, **Copilot CLI generates the item-specific manual verification guidance**,
   helps you decide **Pass/Fail**, and records it with the skill's `resolve_review` command.
5. Copilot shows the final **summary/report** via `show_reports`.

## GitHub Copilot (VS Code) integration via MCP

The auditor can be driven from **GitHub Copilot Chat** in VS Code through a Model Context
Protocol (MCP) server. In this mode **Copilot Chat is the AI** — it orchestrates the
conversation, reviews items that need judgement, and (through MCP **sampling**) answers the
generation and validation prompts that `generate_scripts` runs. The server makes **no direct
LLM/API calls**, so **no `PROVIDER_BASE_URL` / `PROVIDER_API_KEY` / `MODEL` is required** for
the IDE flow.

### Tools exposed

| Tool | Purpose |
| --- | --- |
| `load_checklist` | List checklist areas and item IDs (read-only; no SQL needed) |
| `evaluate` | Run the ordered evaluation workflow and return outcomes |
| `generate_scripts` | Run the script-generation pipeline for the given checklist IDs, sampling Copilot for each generation and validation step (no SQL needed) |
| `save_generated_script` / `validate_generated_script` | Fallback for clients without sampling: validate and save a script the model authored from the returned prompt |
| `enrich_result` | Record Copilot-authored Finding/Evidence/RiskImpact/Recommendation for a script-evaluated item |
| `resolve_review` | Record a Pass/Fail decision for an item that needs review |
| `generate_report` | Refresh `historical_last_run.json` and render `final_report.md` + `audit_report.xlsx` (only when the user asks) |
| `show_reports` | Return the generated `final_report.md` or `checklist_results.json` |

### Setup

1. Build the MCP server:

   ```powershell
   dotnet build Backend/IDE/SQLAuditor.Mcp.csproj
   ```

2. Configure `.vscode/mcp.json` (at the workspace root). It launches the built server and
   sets the working directory to `SQL-Auditing-tool` so the engine can find the checklist
   and write `results/`. No LLM key and no SQL credentials are stored here. Windows
   Integrated auth needs nothing extra; for SQL Login, set `SQLAUDITOR_SQL_PASSWORD` in the
   terminal session that launches VS Code (PowerShell: `$env:SQLAUDITOR_SQL_PASSWORD='...'`)
   so the server reads it at runtime without it ever living in this file or in chat:

   ```jsonc
   {
     "servers": {
       "sql-auditor": {
         "type": "stdio",
         "command": "<absolute path>/Backend/IDE/bin/Debug/net8.0/SQLAuditor.Mcp.exe",
         "cwd": "<absolute path>/SQL-Auditing-tool"
       }
     }
   }
   ```

3. In VS Code, **start/restart** the `sql-auditor` server from the MCP view (or the *Start*
   code lens in `mcp.json`). Confirm the tools appear in Copilot's **Configure Tools** list.

### Usage (Copilot Agent chat)

Open Copilot Chat in **Agent** mode and ask it to run an audit. The workflow mirrors the CLI:

1. Copilot asks whether to **use the last runs' manual results** or run a **fresh evaluation**.
2. Copilot asks for the **SQL Server name**.
3. Then the **authentication method** (`windows` or `sql`; for SQL Login it asks the
   username — the password is read from the `SQLAUDITOR_SQL_PASSWORD` session environment
   variable you set in your terminal, never typed in chat or stored in `mcp.json`).
4. Then **which checklist items** to evaluate (e.g. `1.2.1, 3.1.2`).
5. Copilot calls `evaluate`; script-based controls are decided deterministically, and manual
   items reused from a previous run come back already decided.
6. For **Needs Review** items, Copilot presents the verification guidance, helps you decide,
   and records each decision via `resolve_review`.
7. Copilot asks whether to generate the summary/report. On yes it calls `generate_report`
   (which refreshes `historical_last_run.json`) and then shows it with `show_reports`.

Example prompts: `use load_checklist`, `evaluate checklist 1.2.1 and 3.1.2`,
`mark 3.1.1 as pass, notes: verified naming standards`,
`generate scripts for checklist 1.1.2, 3.1.1` (this calls `generate_scripts`, never
`evaluate`).

## Output

Each audit run writes its artefacts to a timestamped, server-specific directory:

```text
results/<yyyyMMdd_HHmmss_fff>_<server-name>/
```

The timestamp uses local time. Characters that are unsafe in a directory name are replaced with
underscores, so `tcp:sql01.example.com,1433` becomes a suffix such as
`tcp_sql01.example.com_1433`. Follow-up commands such as `generate_report`, `show_reports`,
`resolve_review`, and `enrich_result` automatically use the latest run containing
`checklist_results.json`. Existing files directly under `results/` remain readable for backward
compatibility.

| File | Contents |
| --- | --- |
| `checklist_results.json` | Per-item outcome, technique and token usage |
| `historical_last_run.json` | Completed manual/AI-Manual results keyed by checklist ID, reusable by later runs; refreshed only at report generation |
| `final_report.md` | Rendered audit report with weighted scores |
| `ui_log.txt` | Diagnostic log; the first place to look when a run fails |

The `results/` folder is git-ignored, as its directory names and logs can contain server details.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Setting 'PROVIDER_API_KEY' still holds the placeholder value` | The variable (or the `.env` entry) holds a `<placeholder>` instead of a real value |
| `generate_scripts` falls back to "this client did not offer sampling" | The MCP client does not support `sampling/createMessage`; answer the returned prompt and save with `save_generated_script` |
| `401 Unauthorized` from the provider | Invalid or expired API key |
| `error code: 524` or `TaskCanceledException` | The LLM took too long; the request exceeded the provider gateway limit |
| `Could not open a connection to SQL Server` | Wrong FQDN, instance not running, or TCP/named pipes disabled |

## Note on the console project

`Backend/CLI/SQLAuditor.csproj` builds the console executable used by the
[CLI](#command-line-interface-cli) above (it also provides a lightweight interactive menu
when run with no arguments).

