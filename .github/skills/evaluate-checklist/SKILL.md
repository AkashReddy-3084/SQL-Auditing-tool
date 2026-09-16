---
name: evaluate-checklist
description: Audit a SQL Server instance against the governance checklist from inside VS Code, and list, rerun or edit previous audit runs, using the sql-auditor MCP server. Use for "/evaluate <id>", "/evaluate <startId> - <endId>", "/evaluate all", "evaluate checklist 1.1.2", "audit this instance", "run the SQL audit", and also for "show the run history", "evaluation history", "list the last runs", "previous evaluations", "rerun that run", "redo the last audit", "re-evaluate run 2". You are the AI layer — the server runs the deterministic engine and makes no LLM calls. Do NOT use for adding a custom checklist item (that is the configure-checklist skill), from Copilot CLI (that is the sql-auditor skill), or for Copilot session/chat history and standups (that is the chronicle skill) — here "run history" always means SQL audit runs under results/.
license: MIT
---

# Evaluate Checklist (VS Code / MCP)

You are the **AI layer**. The `sql-auditor` MCP server executes the deterministic SQL scripts,
scores them and writes the report files — it makes **no LLM calls**. Everything the WPF app asks
its configured model to do, you do here: author the audit wording for script-evaluated items and
act as the reviewer for items the scripts could not decide.

Use the **MCP tools**. Do **not** shell out to `Backend/CLI/sql-auditor.ps1` — that wrapper is for
Copilot CLI and bypasses this flow.

> **Host check — do this first.** This skill requires the `evaluate`, `enrich_result`,
> `resolve_review`, `generate_report` and `show_reports` tools of the `sql-auditor` MCP server.
> If they are **not** available in the session (you are running in **GitHub Copilot CLI**, or the
> server has not been started in VS Code), do **not** stop and do **not** report the audit as
> impossible: switch to the `sql-auditor` skill (`.github/skills/sql-auditor/SKILL.md`) and run the
> same engine through `Backend/CLI/sql-auditor.ps1`. Only report a failure if that wrapper also
> cannot run.

> **Evaluation, not generation.** Never author or save audit scripts here. Scripts are created
> only by `configure_checklist`, for a NEW custom checklist item.

## Trigger

- `/evaluate 1.1.2` — one checklist item
- `/evaluate 1.1.1 - 2.1.4` — every item between the two IDs, in checklist order
- `/evaluate 1.1.2,3.1.1,4.2.6` — an explicit list
- `/evaluate all` — the whole checklist
- Any natural-language request to evaluate/audit checklist items on an instance
- "show the run history", "evaluation history", "list the last 5 runs", "previous evaluations" —
  audit runs under `results/`, **not** Copilot session history. Call `list_evaluations`.
- "rerun", "redo", "re-evaluate", "run it again", "update that run" — call `rerun_evaluation`.

Pass whatever the user typed straight through as the `items` argument — the tool resolves single
IDs, comma-separated lists, ranges and `all` itself. Do not pre-expand or reformat it.

## Tools

| Tool | Purpose |
|------|---------|
| `evaluate` | Gathers the manual-results choice, server + auth, database scope, runs the engine, returns the work you must do |
| `list_evaluations` | The most recent audit runs across all servers, each with an index to rerun |
| `rerun_evaluation` | Re-runs (or edits) a previous run, overwriting its reports in the SAME folder |
| `enrich_result` | Records the wording **you** author for one item |
| `export_manual_csv` | Exports every manual item, with its verification steps, to a CSV the user fills in. `generateReport=true` also marks undecided manual items Skipped and regenerates the report now |
| `import_manual_csv` | Applies the Pass/Fail decisions from the filled CSV to the run |
| `resolve_review` | Records a single Pass/Fail/Not Applicable decision — corrections only, not the main manual flow |
| `generate_report` | Refreshes the historical manual results and writes the report + workbook |
| `show_reports` | The final report and the authoritative outcome counts |
| `load_checklist` | Look up valid IDs when the user's input cannot be resolved |

## Previous runs (history, rerun, edit)

- **History** — `list_evaluations(count=5)` returns the newest runs with an index, server, date,
  score, item count, status and run directory. Present that list as-is.
- **Rerun / edit** — `rerun_evaluation(run="<index-or-path>", manualResults="last-runs|fresh")`.
  Never use `evaluate` for a rerun: `evaluate` always creates a NEW timestamped folder, while
  `rerun_evaluation` overwrites the reports in the original one.
- The server, authentication and databases are always reused from the original run and cannot be
  changed. Only `items` may be overridden, to edit the checklist selection.
- The manual-results choice must still come from the user. When it is missing the tool returns the
  exact prompt — ask it, then call `rerun_evaluation` **again** with the same `run`.
- Once the rerun finishes, the review/enrichment workflow below applies unchanged.

## Workflow

### 1. Call `evaluate` and answer its questions

```
evaluate(items="<user input verbatim>")
```

It walks six steps and returns the **exact next question** whenever an input is missing. Ask
that question, then call `evaluate` again with the answer plus everything gathered so far.

- **The first question is always the manual-results choice.** Present both options verbatim and
  wait for the user's answer, then pass `manualResults="last-runs"` or `manualResults="fresh"`.
  **Never decide this yourself** and never infer it from context:
  - *Option 1 — Use the Last Runs:* "Do you want me to use the last runs results for the manual steps?"
  - *Option 2 — Fresh Evaluation:* "Do you want to evaluate the checklist items fresh (do not copy
    manual results from previous runs)?"
- **Never guess the server name** or use a default such as `localhost`.
- **Never ask for a password in chat.** For SQL Login the tool needs only the username; the
  password is read from `SQLAUDITOR_SQL_PASSWORD` in the session that launched VS Code.
- **Never choose the databases.** Once the connection details are known, `evaluate` returns a
  `STEP 4b of 6 — DATABASE SELECTION REQUIRED` block listing the user databases on the instance.
  Show that list, let the user pick one, several or all of them, then call `evaluate` again with
  `databases="<name1,name2>"` or `databases="all"`. This scope decides which databases the
  database-scoped checks run against, and therefore the Pass/Fail/Not Applicable counts, so it
  must match what the user would have selected in the desktop app. System databases (master,
  model, msdb, tempdb) are never audit targets and are never offered.

With Option 1, manual items that already have a result in `results/historical_last_run.json` are
copied forward and listed as `Copied from last runs (N item(s))`. Those items are **done**: do not
generate manual steps for them, do not review them, and do not enrich them. Manual items without a
historical result still go through the normal review flow below.

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

### 3. Review the items the scripts could not decide — via the manual CSV

Manual items are decided through a **CSV export/import**, the same workflow the desktop app uses.
Do **not** ask for these decisions one item at a time, and do **not** paste the verification steps
into the chat — the CSV already carries them.

1. **First ask the user which they want** — do not export or import anything until they answer:
   - **(a) Import an already-filled CSV** they have (for example one they filled during a previous
     run). Ask for its path and call `import_manual_csv(path="<that path>")`. A CSV from an earlier
     run works because rows are matched by `Checklist ID`; rows for items not in this run are
     ignored. Do **not** export a new CSV in this case.
   - **(b) Export a fresh CSV to fill now.** Call `export_manual_csv()`. It writes every manual item —
     with its area, description, verification and the verification steps already in the
     **`Manual Steps`** column — to a timestamped `manual_checks_*.csv` in the run directory. Give the
     user **only the path** and a one-line instruction: for each row, fill the **`Decision`** column
     with `Pass` or `Fail` and the **`Evidence`** column with what they inspected and found, leaving
     **`Checklist ID`** unchanged. The verdict is theirs — never infer it, assume it, announce it, or
     argue for a different one. Show a single item's steps in chat **only if the user explicitly asks**.
2. When the user gives you a filled CSV (whether an existing one or the one just exported), call
   `import_manual_csv(path="<that path>")`. Rows are matched by `Checklist ID`, so each row records a
   new decision **or overwrites an existing one** — the CSV is the source of truth. Accept the entries
   as given: do not judge whether the evidence is sufficient and do not ask for extra detail. Report
   back only the rows the import flagged as ignored or needing correction, and let the user fix and
   re-import.
3. Use `resolve_review(id, decision, notes)` only to correct a single item afterwards, or to record
   `decision="notapplicable"` when what the user reports shows the control does not exist on this
   server at all — every value absent, empty, zero or irrelevant, so there is nothing to assess.
   That item is excluded from every score, lands on the workbook's "Not Applicable Items" sheet and
   is reported as **Not Applicable**, never as Pass or Fail; skip step 4 for it. A zero that itself
   proves compliance is a Pass, not this.
4. Call `enrich_result` for every applied item with wording **you** derive from their evidence.
   Their raw words must never be left as the report Finding.

### 4. Report

`evaluate` generates the full report suite automatically in the run directory, but it does **not**
refresh `results/historical_last_run.json`.

If the user wants a report **before** the filled CSV comes back, call
`export_manual_csv(generateReport=true)` (the same as the desktop "Export Manual CSV + Generate"
button): every still-undecided manual item is marked **Skipped** and excluded from scoring, and the
report suite is regenerated immediately. A later `import_manual_csv` overwrites those Skipped items
with the user's real decisions and regenerates again.

Once every item is enriched and reviewed, **ask the user whether to generate the final report** —
e.g. "All items are complete. Shall I generate the final report now?" Never generate it silently.
- When the user confirms, call `generate_report()`. This is the step that refreshes
  `results/historical_last_run.json` with the newly evaluated manual results (existing entries are
  preserved) and regenerates the full report suite.
- Then call `show_reports` and report **its** counts — the counts `evaluate` printed are provisional,
  because Not Applicable is decided during enrichment.

## What gets written

| Path | Content |
|------|---------|
| `results/checklist_results.json` | Per-item outcome, score, severity and your wording |
| `results/historical_last_run.json` | Manual/AI-Manual results keyed by checklist ID, reusable by later runs (refreshed only by `generate_report`) |
| `Audit Report.md` | Scored Markdown audit report |
| `Audit Checklist.md` | Per-item checklist rendering |
| `Risk Register.md` | Risk register derived from the failed items |
| `OT Server SQL Assessment Readout 3.html` | HTML readout |
| `audit-report-vrsvpsql1c-mlcot-local.xlsx` | 5-tab workbook: Summary, Area Detail, Checklists, Risk Register, Not Applicable Items |

`enrich_result` and `resolve_review` patch the JSON and regenerate every artifact on each call —
never edit these files by hand.
