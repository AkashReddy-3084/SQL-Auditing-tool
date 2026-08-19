# SQL Auditor

Desktop application that audits a SQL Server instance against a governance checklist. Controls are evaluated three ways: deterministic T-SQL scripts, AI-assisted evaluation against a live connection, and AI-generated manual verification steps for controls that cannot be checked automatically.

High-level architecture and flow documentation: see `ARCHITECTURE.md`.

## Prerequisites

| Requirement | Version | Notes |
| --- | --- | --- |
| Windows | 10 or later | The UI is WPF; it does not run on Linux or macOS |
| .NET SDK | 10.0 or later | Projects target `net10.0`; verified on SDK 10.0.302 |
| .NET Desktop Runtime | 10.0 or later | Ships with the SDK |
| SQL Server | 2016 or later | Local or remote; SQL Server Express is fine |
| Git | any recent version | To clone the repository |

You will also need:

- A Windows account or SQL login on the target instance with at least `VIEW SERVER STATE`.
- An OpenAI-compatible LLM endpoint and API key, for the AI-assisted checks.

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

### 2. Create your configuration file

```powershell
Copy-Item .env.example .env
```

### 3. Fill in `.env`

Open `.env` and set each value:

| Key | Required | Description |
| --- | --- | --- |
| `PROVIDER_BASE_URL` | Yes | Base URL of the LLM endpoint, without `/chat/completions` |
| `PROVIDER_API_KEY` | Yes | Bearer token for the endpoint |
| `MODEL` | Yes | Model name to request |
| `PROVIDER_TIMEOUT_SECONDS` | No | HTTP timeout in seconds; defaults to 240 |

`.env` is git-ignored and must never be committed. Values in `.env` take precedence over any environment variables of the same name, so a stale variable left over on your machine cannot break the app.

### 4. Restore dependencies

```powershell
dotnet restore Frontend/MainWindow/SQLAuditor.Wpf.csproj
```

### 5. Build

```powershell
dotnet build Frontend/MainWindow/SQLAuditor.Wpf.csproj
```

### 6. Run

```powershell
dotnet run --project Frontend/MainWindow/SQLAuditor.Wpf.csproj
```

## Using the application

1. **Login** — enter the SQL Server FQDN, choose Windows Authentication or SQL Login, and click *Verify Access*. Named instances such as `localhost\SQLEXPRESS` are supported.
2. **Checklist** — select the controls to evaluate.
3. **Evaluate** — script and AI checks run in parallel. Controls needing human judgement appear with generated verification steps for you to mark Pass or Fail.
4. **Summary** — generates the scored report and lets you export it.

## Command-line interface (CLI)

The same evaluation engine is available as a console command for automation and CI. It
reuses the checklist, scoring, and report generation. The CLI makes **no LLM/API calls**
and needs **no `.env` / `PROVIDER_BASE_URL` / `PROVIDER_API_KEY` / `MODEL`**. Controls that
need human judgement come back as **Needs Review** for a person — or GitHub Copilot CLI — to
decide.

### Build

```powershell
dotnet build Backend/core/SQLAuditor.csproj
```

This produces `Backend/core/bin/Debug/net10.0/SQLAuditor.exe`.

### Run an evaluation

```powershell
Backend\core\bin\Debug\net10.0\SQLAuditor.exe evaluate [options]
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
Databases Verified stay script-derived); `show_reports [--kind json]`
prints the latest report; `--dump-checklist` lists the checklist structure.

Examples:

```powershell
# Fully interactive (prompts for server, auth, and items)
Backend\core\bin\Debug\net10.0\SQLAuditor.exe evaluate

# Non-interactive with flags
Backend\core\bin\Debug\net10.0\SQLAuditor.exe evaluate --items 1.1.2,3.1.2 --server localhost

# Copilot CLI mode: surface Needs Review items for Copilot to review
Backend\core\bin\Debug\net10.0\SQLAuditor.exe evaluate --copilot --items 1.1.2,3.1.2 --server localhost

# List the checklist structure without running an evaluation
Backend\core\bin\Debug\net10.0\SQLAuditor.exe --dump-checklist
```

### Manual review and output

Script-based controls are decided automatically. Controls needing human judgement come back
as **Needs Review**; in an interactive terminal (or with `--interactive`) the CLI shows the
verification guidance and prompts you to mark each **Pass**, **Fail**, or **Skip** (with
optional notes). Results are written to `results/checklist_results.json` and
`results/final_report.md` (see [Output](#output)).

The command returns an exit code for scripting: `0` success, `1` one or more controls
failed, `2` usage/validation error, `3` unexpected error.

## GitHub Copilot CLI integration (skill)

The auditor can be driven from **GitHub Copilot CLI** using the `sql-auditor` skill in
`.github/skills/sql-auditor/`. In this mode **Copilot CLI itself is the AI layer** — signed
in with the same GitHub Copilot account used by `/login`. The `SQLAuditor` CLI runs the
evaluation engine only and makes **no LLM/API calls**; **no `.env` / `PROVIDER_BASE_URL` /
`PROVIDER_API_KEY` / `MODEL`** is used or requested.

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
conversation and reviews items that need judgement. The MCP server itself makes **no
direct LLM/API calls**, so **no `PROVIDER_BASE_URL` / `PROVIDER_API_KEY` / `MODEL` is
required** for the IDE flow.

### Tools exposed

| Tool | Purpose |
| --- | --- |
| `load_checklist` | List checklist areas and item IDs (read-only; no SQL needed) |
| `evaluate` | Run the ordered evaluation workflow and return outcomes |
| `enrich_result` | Record Copilot-authored Finding/Evidence/RiskImpact/Recommendation for a script-evaluated item |
| `resolve_review` | Record a Pass/Fail decision for an item that needs review |
| `show_reports` | Return the generated `final_report.md` or `checklist_results.json` |

### Setup

1. Build the MCP server:

   ```powershell
   dotnet build Backend/agents/modules/IDE/SQLAuditor.Mcp.csproj
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
         "command": "<absolute path>/Backend/agents/modules/IDE/bin/Debug/net10.0/SQLAuditor.Mcp.exe",
         "cwd": "<absolute path>/SQL-Auditing-tool"
       }
     }
   }
   ```

3. In VS Code, **start/restart** the `sql-auditor` server from the MCP view (or the *Start*
   code lens in `mcp.json`). Confirm the tools appear in Copilot's **Configure Tools** list.

### Usage (Copilot Agent chat)

Open Copilot Chat in **Agent** mode and ask it to run an audit. The workflow mirrors the CLI:

1. Copilot asks for the **SQL Server name**.
2. Then the **authentication method** (`windows` or `sql`; for SQL Login it asks the
   username — the password is read from the `SQLAUDITOR_SQL_PASSWORD` session environment
   variable you set in your terminal, never typed in chat or stored in `mcp.json`).
3. Then **which checklist items** to evaluate (e.g. `1.2.1, 3.1.2`).
4. Copilot calls `evaluate`; script-based controls are decided deterministically.
5. For **Needs Review** items, Copilot presents the verification guidance, helps you decide,
   and records each decision via `resolve_review`.
6. Copilot shows the final **summary/report** (`show_reports`).

Example prompts: `use load_checklist`, `evaluate checklist 1.2.1 and 3.1.2`,
`mark 3.1.1 as pass, notes: verified naming standards`.

## Output

Generated artefacts are written to `results/` in the working directory:

| File | Contents |
| --- | --- |
| `checklist_results.json` | Per-item outcome, technique and token usage |
| `final_report.md` | Rendered audit report with weighted scores |
| `ui_log.txt` | Diagnostic log; the first place to look when a run fails |

The `results/` folder is git-ignored, as it contains server names and connection details.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Setting 'PROVIDER_API_KEY' still holds the placeholder value` | `.env` was copied but not filled in, or an environment variable of the same name holds a placeholder |
| `401 Unauthorized` from the provider | Invalid or expired API key |
| `error code: 524` or `TaskCanceledException` | The LLM took too long; the request exceeded the provider gateway limit |
| `Could not open a connection to SQL Server` | Wrong FQDN, instance not running, or TCP/named pipes disabled |

## Note on the console project

`Backend/core/SQLAuditor.csproj` builds the console executable used by the
[CLI](#command-line-interface-cli) above (it also provides a lightweight interactive menu
when run with no arguments).

