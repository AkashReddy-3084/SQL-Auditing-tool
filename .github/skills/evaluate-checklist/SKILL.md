---
name: evaluate-checklist
description: Audit a SQL Server instance against the governance checklist from inside VS Code, using the sql-auditor MCP server. Use for "/evaluate <id>", "/evaluate <startId> - <endId>", "/evaluate all", "evaluate checklist 1.1.2", "audit this instance", "run the SQL audit". You are the AI layer — the server runs the deterministic engine and makes no LLM calls. Do NOT use for script GENERATION (that is the generate-script skill) or from Copilot CLI (that is the sql-auditor skill).
license: MIT
---

# Evaluate Checklist (VS Code / MCP)

You are the **AI layer**. The `sql-auditor` MCP server executes the deterministic SQL scripts,
scores them and writes the report files — it makes **no LLM calls**. Everything the WPF app asks
its configured model to do, you do here: author the audit wording for script-evaluated items and
act as the reviewer for items the scripts could not decide.

Use the **MCP tools**. Do **not** shell out to `tools/sql-auditor.ps1` — that wrapper is for
Copilot CLI and bypasses this flow.

> **Evaluation, not generation.** Never call `generate_scripts` or `save_generated_script` here.

## Trigger

- `/evaluate 1.1.2` — one checklist item
- `/evaluate 1.1.1 - 2.1.4` — every item between the two IDs, in checklist order
- `/evaluate 1.1.2,3.1.1,4.2.6` — an explicit list
- `/evaluate all` — the whole checklist
- Any natural-language request to evaluate/audit checklist items on an instance

Pass whatever the user typed straight through as the `items` argument — the tool resolves single
IDs, comma-separated lists, ranges and `all` itself. Do not pre-expand or reformat it.

## Tools

| Tool | Purpose |
|------|---------|
| `evaluate` | Gathers server + auth, runs the engine, returns the work you must do |
| `enrich_result` | Records the wording **you** author for one item |
| `resolve_review` | Records the user's Pass/Fail decision for one review item |
| `show_reports` | The final report and the authoritative outcome counts |
| `load_checklist` | Look up valid IDs when the user's input cannot be resolved |

## Workflow

### 1. Call `evaluate` and answer its questions

```
evaluate(items="<user input verbatim>")
```

It walks five steps and returns the **exact next question** whenever an input is missing. Ask
that question, then call `evaluate` again with the answer plus everything gathered so far.

- **Never guess the server name** or use a default such as `localhost`.
- **Never ask for a password in chat.** For SQL Login the tool needs only the username; the
  password is read from `SQLAUDITOR_SQL_PASSWORD` in the session that launched VS Code.

### 2. Enrich every script-evaluated item

The `=== COPILOT ENRICHMENT REQUIRED ===` block lists the items whose verdict is decided but
whose wording is not. **Outcome, Score, Severity and Databases Verified are script-derived —
never change them.** For each item, using only the facts under `Finding` and `Script result`
(no invented objects, counts, databases or settings):

- `finding` — 1–2 sentences on the actual state found, not a restatement of the checklist text
- `evidence` — how that finding justifies the outcome, quoting the returned values (< 120 words)
- `riskImpact` — the specific consequence of *this* finding (< 50 words, no generic phrases)
- `recommendation` — remediation targeted at this gap; omit when Score is 3 and Outcome is Pass

**The Not Applicable rule.** When the `Script result` holds no supporting artefact at all —
every value NULL, empty, zero or "not found" — the control does not exist to be assessed. Start
the evidence with the exact words `Not Applicable.` followed by one sentence of your own
reasoning naming what the script looked for and where. `enrich_result` then re-stamps the item
to Outcome `Not Applicable`, drops it from every score and lists it on the workbook's "Not
Applicable Items" sheet — report it as **Not Applicable**, never as Pass or Fail. A zero that
proves compliance ("0 unauthorised logins" on a Pass) is real evidence, not "Not Applicable".

Call `enrich_result` per item and keep going. Work through the list in batches rather than
pausing after each one, and do not write a summary until every listed item is recorded.

### 3. Review the items the scripts could not decide

For **every** entry in the `=== COPILOT REVIEW REQUIRED ===` block you are the reviewer:

1. Present the full verification guidance first, in the exact output format the tool prints
   (Checklist / Objective / Manual Verification Steps / What indicates a PASS and a FAIL /
   Recommended Actions), filled with item-specific content and real T-SQL. Do this for every
   item before asking anything.
2. Ask for the user's **Pass/Fail decision**. The verdict is theirs — never infer it, assume it,
   announce it, or argue for a different one.
3. Ask **one** follow-up: what they inspected and what they found. Accept the answer as given.
4. Call `resolve_review(id, decision, notes=<their own words>)`.
5. Call `enrich_result` for the same item with wording **you** derive from their evidence. Their
   raw words must never be left as the report Finding.

### 4. Report

The counts `evaluate` prints are **provisional** — Not Applicable is decided during enrichment.
Once every item is enriched and reviewed, call `show_reports` and report the counts it returns.

## What gets written

| Path | Content |
|------|---------|
| `results/checklist_results.json` | Per-item outcome, score, severity and your wording |
| `results/final_report.md` | Scored Markdown audit report |
| `results/audit_report.xlsx` | 5-tab workbook: Summary, Area Detail, Checklists, Risk Register, Not Applicable Items |

`enrich_result` and `resolve_review` patch the JSON and regenerate both reports on every call —
never edit these files by hand.
