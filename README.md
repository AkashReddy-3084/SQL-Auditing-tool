# SQL Auditor

Desktop application that audits a SQL Server instance against a governance checklist. Controls are evaluated three ways: deterministic T-SQL scripts, AI-assisted evaluation against a live connection, and AI-generated manual verification steps for controls that cannot be checked automatically.

High-level architecture and flow documentation: see `ARCHITECTURE.md`.

## Prerequisites

| Requirement | Version | Notes |
| --- | --- | --- |
| Windows | 10 or later | The UI is WPF; it does not run on Linux or macOS |
| .NET SDK | 8.0 or later | Projects target `net8.0`; verified on SDK 10.0.302 |
| .NET Desktop Runtime | 8.0 or later | Ships with the SDK |
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

`Backend/core/SQLAuditor.csproj` is a legacy console entry point and does not currently compile. Use the WPF application above.

