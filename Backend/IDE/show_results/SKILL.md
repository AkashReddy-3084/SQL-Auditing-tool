# Skill: show_reports

> Design/spec only. No code wiring yet.

## Purpose
Surface the most recently generated audit outputs in the IDE so a user can review
results without leaving VS Code. Read-only over files the engine already writes.

## Trigger (intended)
- Chat usage, e.g. `/show_reports` or `/show_reports summary`.
- Exposed as an MCP tool named `show_reports` from the IDE host under `IDE/`.

## Inputs
| Name   | Required | Description                                                       |
|--------|----------|-------------------------------------------------------------------|
| kind   | No       | `summary` (Audit Report.md) or `json` (checklist_results.json).   |
|        |          | Defaults to `summary`.                                            |

## Behavior
1. Locate the `results/` folder (same repo-root resolution the engine uses).
2. Read the requested artifact:
   - `summary` -> the active run's `Audit Report.md`
   - `json`    -> `results/checklist_results.json`
3. Return its contents (or a rendered summary of pass/fail counts).

## Output
- For `summary`: the Markdown report content.
- For `json`: the raw results, or a compact per-item outcome table.
- Clear message if no results exist yet (prompt the user to run `evaluate` first).

## Reuses
- Reads existing engine outputs; no new computation.
- Same report produced by `SqlAuditor.Reporting.ReportSuiteGenerator`.

## Out of scope
- No re-evaluation, no report regeneration, no DB/LLM access.
