---
name: sql-auditor
description: Run the repository's SQL Auditor from GitHub Copilot CLI, or from any session where the sql-auditor MCP tools are unavailable. Use for "evaluate checklist 1.1.2", "evaluate checklist 1.1.1 - 1.3.10", "audit this instance", "run the SQL audit" and "add a custom checklist item" whenever the MCP tools cannot be called — everything runs through Backend/CLI/sql-auditor.ps1. Copilot CLI is the AI layer — the CLI runs only the existing evaluation engine (no LLM, no .env/PROVIDER_*), and Copilot tailors manual verification guidance for Needs Review items and collects the decisions through the manual CSV (export_manual_csv / import_manual_csv). Windows/SQL authentication is unchanged. Scripts are authored only as part of configure_checklist, for a NEW custom checklist item.
license: MIT
allowed-tools: shell
---

# SQL Auditor (Copilot CLI)

You (Copilot CLI) are the **AI layer** for this audit — signed in with the same GitHub
Copilot account used by `/login`. The `SQLAuditor` CLI executes **only** the existing
evaluation engine (deterministic scripts + the built-in manual workflow) and exposes the
results. It makes **no LLM/API calls** and does **not** read `.env`, `PROVIDER_BASE_URL`,
`PROVIDER_API_KEY`, or `MODEL`. Never ask the user to choose "script-only" vs "AI-assisted"
or to supply any LLM configuration.

All commands run from the repository root (`SQL-Auditing-tool`) via the wrapper script
`Backend/CLI/sql-auditor.ps1`, which locates or builds `SQLAuditor.exe` automatically.

> **When to use this skill instead of the MCP skills.** `evaluate-checklist` and
> `configure-checklist` only work when the `sql-auditor` MCP server is connected (VS Code). In
> Copilot CLI — or in any session where those tools are missing — use this skill: it drives the
> **same** engine through the wrapper script and needs no MCP server. Never tell the user the audit
> cannot run because the MCP tools are unavailable; run the commands below instead.

> **Manual review is CSV-based.** After running `evaluate`, do NOT dump the verification steps into
> the chat. Run `export_manual_csv` and hand the user the file path: the steps are already in the
> CSV's `Manual Steps` column and the user fills the `Decision` and `Evidence` columns there. Show a
> single item's steps in chat only if the user explicitly asks for that item.

> **There is no standalone script-generation command.** Audit scripts are authored **only** by
> `configure_checklist`, and only for the ONE new custom checklist item it reserves. Existing and
> default checklist items already have their scripts and are never regenerated. If the user asks to
> "generate a script", ask whether they want to **add a new custom checklist item** and run
> `configure_checklist`; otherwise run `evaluate`.

> **Rerun/redo a previous run — use `rerun`, NEVER `evaluate`.**
> When the user asks to "rerun", "redo", "re-evaluate", "update", or "run again" a previous
> evaluation (or points at a run from `history`), use the **rerun** command below. It overwrites
> the reports **in the original run folder**. Do NOT call `evaluate` for this — `evaluate` always
> creates a NEW timestamped folder. The server, authentication and databases are reused from the
> original run and cannot be changed; only `--items` may be edited.

## Commands

- **evaluate** — run the evaluation engine (no LLM) and surface Needs Review items:
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 evaluate --copilot --manual-results <last-runs|fresh> --items <ids> --server <host> --databases <names|all> [--user <name>]
  ```
  `--manual-results` is **required** and must come from the user (see step 1 below).
  `--databases` is **required** in `--copilot` mode and must also come from the user (see step 2b):
  without it the command prints the list of user databases on the instance and stops.
- **history** — list the most recent runs across all servers (newest first, each with an index):
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 history
  ```
- **rerun** — re-run (or edit) a previous run, overwriting its reports in the SAME folder:
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 rerun --run <index-or-path> --copilot --manual-results <last-runs|fresh> [--items <ids>]
  ```
  `--run` is an index from `history` or a run directory path. The server, authentication and
  databases are reused from that run; pass `--items` only to edit the checklist selection. Like
  `evaluate`, `--manual-results` is **required** and must come from the user. This updates the
  original folder — it does NOT create a new run directory.
- **generate_report** — refresh the historical manual results and render the final outputs:
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 generate_report
  ```
- **export_manual_csv** — export every manual item, with its verification steps, for offline review:
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 export_manual_csv [--out <path>]
  ```
- **import_manual_csv** — apply the Pass/Fail decisions from the filled CSV:
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 import_manual_csv --file <path>
  ```
  Rows are matched by `Checklist ID`, so a row records a new decision **or overwrites an existing one**.
- **resolve_review** — record a single decision (corrections and `notapplicable` only, not the main
  manual flow):
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 resolve_review --id <id> --decision <pass|fail|needsreview|notapplicable> --notes "<rationale>"
  ```
- **enrich_result** — record the audit wording you authored for one script-evaluated item:
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 enrich_result --id <id> --finding "<finding>" --evidence-file "<path>" --risk "<riskImpact>" --recommendation "<recommendation>"
  ```
  Every field also has a file form — `--finding-file`, `--evidence-file`, `--risk-file`,
  `--recommendation-file` — and `resolve_review` has `--notes-file`. **A quote character inside
  the text is eaten by the shell**, so write any field that quotes returned values (evidence,
  above all) to a file and pass the path instead of the text.
- **load_checklist** — list the checklist structure (read-only):
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 --dump-checklist
  ```
- **show_reports** — print the generated report (add `--kind json` for raw results):
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 --show-reports
  ```

## Workflow (drive this end to end)

1. **Ask how manual checklist items should be handled — before anything else.** Present both
   options verbatim and wait for the user's answer; never decide this yourself:
   - *Option 1 — Use the Last Runs:* "Do you want me to use the last runs results for the manual steps?"
   - *Option 2 — Fresh Evaluation:* "Do you want to evaluate the checklist items fresh (do not copy
     manual results from previous runs)?"

   Pass their answer through as `--manual-results last-runs` or `--manual-results fresh`. Running
   `evaluate --copilot` without it prints the question block and stops. With Option 1, manual items
   already recorded in `results/historical_last_run.json` are copied forward: they come back decided,
   never appear in the review block, and must not be re-reviewed or re-enriched. Manual items with no
   historical result still follow the normal review flow.
2. Run **evaluate** with the checklist `--items` and `--server`. For SQL Login pass
   `--user <name>`; the password comes from the `SQLAUDITOR_SQL_PASSWORD` session
   environment variable — **never** ask for it in chat. Omit `--user` for Windows
   Integrated authentication. The CLI runs the engine only; it never calls an LLM.
2b. **Ask which databases to audit.** Without `--databases`, `evaluate --copilot` prints a
   `=== DATABASE SELECTION REQUIRED ===` block listing the user databases on the instance and
   stops. Show that list to the user, let them pick one, several or all, and run `evaluate`
   again with `--databases <name1,name2>` or `--databases all`. Never choose for them: the
   scope decides which databases the database-scoped checks run against, and therefore the
   Pass/Fail/Not Applicable counts. System databases (master, model, msdb, tempdb) are never
   audit targets and are never offered.
3. Read the `=== COPILOT ENRICHMENT REQUIRED ===` block. Script-evaluated items already
   have their Outcome, Score, Severity and Databases Verified decided — **never change
   those**. For each item you author the wording from the `Script result` shown there,
   using only the facts it contains (no invented objects, counts, databases or settings):
   - `finding` — 1–2 sentences on the actual state found, not a restatement of the checklist text
   - `evidence` — how that finding justifies the outcome, quoting the returned values (< 120 words).
     When the `Script result` holds **no** supporting artefact at all (every value NULL, empty,
     zero or "not found"), the control does not exist to be assessed: start the evidence with the
     exact words `Not Applicable.` followed by one sentence of your own reasoning. A zero that
     itself proves compliance is real evidence, not "Not Applicable".
   - `riskImpact` — the specific consequence of *this* finding (< 50 words, no generic phrases)
   - `recommendation` — remediation targeted at this gap; leave empty when Score is 3 and Outcome is Pass

   Record each one with **enrich_result** before moving on, writing the evidence to a file and
   passing `--evidence-file` so the quotes it contains survive. When the command replies that the
   item moved to Outcome `Not Applicable`, that item is excluded from every score and is listed on
   the workbook's "Not Applicable Items" sheet — report it as **Not Applicable**, never as Pass or Fail.
4. Read the `=== COPILOT REVIEW REQUIRED ===` block, then run **export_manual_csv**. It writes
   every manual item — with its area, description, verification and the verification steps already in
   the **`Manual Steps`** column — to a timestamped `manual_checks_*.csv` in the run directory. Give
   the user **only that path** and a one-line instruction — do **not** paste the steps, a Pass/Fail
   rubric or any per-item guidance into chat; the steps live in the CSV. For each row the user fills
   the **`Decision`** column with `Pass` or `Fail` and the **`Evidence`** column with what they
   inspected and found, leaving **`Checklist ID`** unchanged. The verdict is the reviewer's to make:
   never infer it, assume it, announce it, or challenge it. Do **not** ask for these decisions one
   item at a time. Show a single item's steps in chat — in the format below — **only if the user
   explicitly asks** for that item:

   ```
   Checklist: <title>
   Objective: <one sentence>

   ## Manual Verification Steps:
   1. ... (include ```sql blocks where a query is needed)

   ## What indicates a PASS and a FAIL
   Pass:
   - ...
   Fail:
   - ...

   ## Recommended Actions (if failed)
   - ...
   ```
6. When the user says the file is ready, run **import_manual_csv** with `--file <path>`. Accept their
   entries as given — do not judge whether the evidence is sufficient and do not ask for more detail.
   Report back only the rows the import listed as ignored or needing correction, and let the user fix
   the CSV and re-import; re-importing overwrites decisions that were already recorded.
7. Run **enrich_result** for each applied item with wording *you* derive from their evidence — finding,
   evidence, riskImpact and recommendation, using only facts they stated. The reviewer's raw words
   must never be left as the report Finding.
   - Use **resolve_review** with `--decision notapplicable` when what the user reports shows the control
     does not exist on this server at all — every value absent, empty, zero or irrelevant to the item,
     so there is nothing to assess. The item is then excluded from every score, listed on the workbook's
     "Not Applicable Items" sheet and reported as **Not Applicable**, never as Pass or Fail, and it
     needs no `enrich_result` call. A zero that itself proves compliance is a Pass, not this.
     `resolve_review` is also how you correct a single item after an import.
8. Do not write a final summary until every review item is resolved and every script item
   is enriched. The full report suite is generated automatically by `evaluate` in the run
   directory (but `results/historical_last_run.json` is **not** refreshed there).
9. **Once every item is resolved and enriched, ASK the user whether to generate the final
   report** — e.g. "All items are complete. Shall I generate the final report now?" Wait for
   their answer; never generate it silently.
   - When the user confirms, run **generate_report**. This is the step that refreshes
     `results/historical_last_run.json` with the newly evaluated manual results (existing entries
     are preserved) and regenerates the full report suite in the run directory.
   - Then run **show_reports** and report **its** counts — the counts `evaluate` printed are
     provisional, because Not Applicable is decided during enrichment.

## Generating scripts (only for NEW custom checklist items)

There is no standalone script-generation command. A script is authored **only** while
`configure_checklist` adds a NEW custom checklist item, and only for the single ID that flow
reserves. Existing and default checklist items are never regenerated.

Run `configure_checklist` (see `Backend/Modules/configure_checklist`) and follow the prompts it
prints: guardrails → semantic match → Area/Sub-area classification → script generation → C1-C7
review → user approval. Nothing reaches `custom-checklist.json`,
`custom-deterministic-script-mapping.json` or `Backend/checklists/Scripts/` until the user approves.

## Examples

```powershell
# Evaluate two controls against a local server (Windows auth, fresh manual evaluation)
# Run it first without --databases to get the list of databases to offer the user.
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 evaluate --copilot --manual-results fresh --items 1.1.1,3.1.4 --server localhost --databases AdventureWorks2025

# Re-run reusing the manual results recorded by the previous audit
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 evaluate --copilot --manual-results last-runs --items 1.1.1,3.1.4 --server localhost --databases all

# Export the manual checklist items for the user to fill in offline
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 export_manual_csv

# Apply the decisions once the user has filled the Decision/Evidence columns
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 import_manual_csv --file "results\<run>\manual_checks_20260915_162306.csv"

# Correct a single item, or record one that is not applicable at all
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 resolve_review --id 3.1.4 --decision pass --notes "SET NOCOUNT ON present in all procs"

# Show the final report
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 generate_report
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 --show-reports
```

## Notes

- The wrapper only invokes the existing CLI binary (or builds/runs the project); it does
  not change authentication, add LLM settings, or duplicate evaluation logic.
- No external LLM or API calls are introduced anywhere in the CLI.
- Requires the .NET SDK if `SQLAuditor.exe` is not already built.
- Uses relative repository paths so it works after cloning.
