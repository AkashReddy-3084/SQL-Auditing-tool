# Skill: evaluate

> Design/spec only. No code wiring yet.

## Purpose
Evaluate one or more checklist items directly from the IDE (VS Code Copilot Chat),
returning a pass/fail result plus a short summary. This is the IDE equivalent of the
CLI `evaluate` command and reuses the same evaluation engine.

## Trigger (intended)
- Chat/slash usage, e.g. `/evaluate 1.1.2,3.1.2`
- Exposed as an MCP tool named `evaluate` from the IDE host under `IDE/`.

## Inputs
| Name    | Required | Description                                              |
|---------|----------|----------------------------------------------------------|
| manualResults | Yes | `last-runs` or `fresh`. Must come from the user; decides whether manual/AI-Manual results in `results/historical_last_run.json` are copied forward. |
| items   | Yes      | Comma-separated checklist IDs (e.g. `1.1.2,3.1.2`).      |
| server  | Yes*     | SQL Server host[,port]. From arg/env `SQLAUDITOR_SERVER`.|
| user    | No       | SQL login user. Omit for Windows Integrated auth.        |
| password| No       | SQL login password (never logged/echoed).                |

\* May be supplied via environment/VS Code settings rather than per-call.

## Behavior
1. Ask the user how manual items are handled (last runs vs fresh) before anything else.
2. Load the checklist structure and validate requested IDs (warn + skip unknown IDs).
3. Run only the selected items through the existing engine
   (`Auditor.RunChecklistAsync(selectedIds: ...)`). With `last-runs`, manual items that already
   have a completed result in `results/historical_last_run.json` are copied forward and skip
   manual-step generation and manual review entirely.
4. Non-interactive: no operator prompts; manual-only items resolve to `NeedsReview`.
5. Write `results/checklist_results.json` and automatically generate `Audit Checklist.md`,
   `Audit Report.md`, `Risk Register.md`, `OT Server SQL Assessment Readout 3.html`, and
   `audit-report-vrsvpsql1c-mlcot-local.xlsx` in the active run directory.

## Output
- Per-item lines: `[<id>] <Outcome> (<Technique>) - <Description>`
- A summary count grouped by outcome (Pass / Fail / NeedsReview / ...).
- Paths to the generated JSON + report.

## Configuration (no hardcoded secrets)
- SQL: `SQLAUDITOR_SERVER`, `SQLAUDITOR_SQL_USER`. The SQL Login password is read at
  runtime from the `SQLAUDITOR_SQL_PASSWORD` session environment variable only — it is
  never stored in `mcp.json`, source, logs, result files, or chat.
- LLM provider: not used by the IDE/MCP flow (Copilot Chat is the AI); `PROVIDER_BASE_URL`,
  `PROVIDER_API_KEY`, and `MODEL` are ignored here.

## Reuses
- `SQLAuditor.Lib.Auditor.RunChecklistAsync(progress, requestUserInput: null, selectedIds, ct, useHistoricalManualResults, generateReports: true)`
- `SQLAuditor.Lib.Auditor.GenerateReports(refreshHistoricalManualResults)` (via the `generate_report` tool)
- `SQLAuditor.Lib.HistoricalManualResultsStore` (load / reuse / refresh)
- `SQLAuditor.Lib.Auditor.GetChecklistStructureAsync()` (for ID validation)

## Out of scope
- No changes to checklist content or scoring logic.
- No new LLM providers.
