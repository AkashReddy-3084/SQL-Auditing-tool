# Skill: load_checklist

> Design/spec only. No code wiring yet.

## Purpose
List the audit checklist structure from the IDE so a user can discover valid item IDs
before running `evaluate`. Read-only; requires no SQL Server or LLM provider.

## Trigger (intended)
- Chat usage, e.g. `/load_checklist` or `/load_checklist 3` (filter by area).
- Exposed as an MCP tool named `load_checklist` from the IDE host under `application/IDE/`.

## Inputs
| Name   | Required | Description                                                    |
|--------|----------|----------------------------------------------------------------|
| area   | No       | Optional area number/name to filter (e.g. `3`).                |
| search | No       | Optional text to match against item IDs or descriptions.       |

## Behavior
1. Load the master checklist via `Auditor.GetChecklistStructureAsync()`.
2. Optionally filter by `area` and/or `search`.
3. Return areas -> categories -> items with `Id` and `Description`.

## Output
- Grouped listing:
  - `Area: <name>`
    - `<id> - <description>`
- Suitable for copy/paste of IDs into an `evaluate` call.

## Reuses
- `SQLAuditor.Lib.Auditor.GetChecklistStructureAsync()`
- (Equivalent to the existing CLI `--dump-checklist` output.)

## Out of scope
- No evaluation, no DB access, no report generation.
