---
name: sql-auditor
description: Run the repository's SQL Auditor from Copilot CLI. Use when asked to audit/evaluate a SQL Server instance against the governance checklist. Copilot CLI is the AI layer — the CLI runs only the existing evaluation engine (no LLM, no .env/PROVIDER_*), and Copilot tailors manual verification guidance for Needs Review items and records decisions with resolve_review. Windows/SQL authentication is unchanged.
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
`tools/sql-auditor.ps1`, which locates or builds `SQLAuditor.exe` automatically.

> **Always show the manual verification steps.** After running `evaluate`, your first
> response must present the full Manual Verification Steps (objective, numbered steps, and
> SQL) for **every** Needs Review item — automatically, every time, without the user asking.
> Only ask for Pass/Fail decisions afterwards.

> **Evaluate vs. generate scripts are two SEPARATE operations.**
> - **"evaluate checklist ..."** → run the **evaluate** command below (connects to a SQL Server,
>   runs the deterministic scripts, and surfaces Needs Review items). This does NOT create scripts.
> - **"generate scripts for checklist ..."** (a.k.a. "create/write audit scripts") → run the
>   **generate_scripts** command below. This authors read-only audit scripts and needs **no**
>   SQL Server and **no** credentials. Never start an evaluation for a script-generation request,
>   and never generate scripts when asked to evaluate.

## Commands

- **evaluate** — run the evaluation engine (no LLM) and surface Needs Review items:
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 evaluate --copilot --items <ids> --server <host> [--user <name>]
  ```
- **resolve_review** — record a decision for one Needs Review item:
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 resolve_review --id <id> --decision <pass|fail|needsreview> --notes "<rationale>"
  ```
- **enrich_result** — record the audit wording you authored for one script-evaluated item:
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 enrich_result --id <id> --finding "<finding>" --evidence "<evidence>" --risk "<riskImpact>" --recommendation "<recommendation>"
  ```
- **generate_scripts** — GENERATE audit scripts for checklist items (no LLM endpoint, no SQL Server):
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 generate_scripts --items <ids>
  ```
- **save_generated_script** — validate and save one script you generated (after generate_scripts):
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 save_generated_script --id <id> --response-file <path-to-raw-response-file>
  ```
- **load_checklist** — list the checklist structure (read-only):
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 --dump-checklist
  ```
- **show_reports** — print the generated report (add `--kind json` for raw results):
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 --show-reports
  ```

## Workflow (drive this end to end)

1. Run **evaluate** with the checklist `--items` and `--server`. For SQL Login pass
   `--user <name>`; the password comes from the `SQLAUDITOR_SQL_PASSWORD` session
   environment variable — **never** ask for it in chat. Omit `--user` for Windows
   Integrated authentication. The CLI runs the engine only; it never calls an LLM.
2. Read the `=== COPILOT ENRICHMENT REQUIRED ===` block. Script-evaluated items already
   have their Outcome, Score, Severity and Databases Verified decided — **never change
   those**. For each item you author the wording from the `Script result` shown there,
   using only the facts it contains (no invented objects, counts, databases or settings):
   - `finding` — 1–2 sentences on the actual state found, not a restatement of the checklist text
   - `evidence` — how that finding justifies the outcome, quoting the returned values (< 120 words)
   - `riskImpact` — the specific consequence of *this* finding (< 50 words, no generic phrases)
   - `recommendation` — remediation targeted at this gap; leave empty when Score is 3 and Outcome is Pass

   Record each one with **enrich_result** before moving on.
3. Read the `=== COPILOT REVIEW REQUIRED ===` block. For **every** item listed there
   (each `--- <id>: <desc> ---` entry), you are the reviewer. **ALWAYS present the full
   Manual Verification Steps for every item automatically, in your very first reply after
   running evaluate — before asking anything.** Never ask the user for a decision, and
   never ask whether to run the queries, until you have first printed the complete steps
   for all items. Do **not** wait to be asked, do **not** summarize, and do **not** just
   say "provide evidence for each". Use the baseline text as your source and render each
   item in this exact format:

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
4. Only **after** the full steps for all items have been shown, ask the user for their
   finding/evidence and decide Pass or Fail together, one item at a time or all at once.
5. Record the decision by running **resolve_review** with `--id`, `--decision`
   (`pass` or `fail`), and `--notes`.
6. Do not write a final summary until every review item is resolved and every script item
   is enriched. Then run **show_reports** to display `results/final_report.md`.

## Generating scripts (separate from evaluation)

When the user asks to **generate/create/write audit scripts** for checklist items, do NOT
evaluate. You (Copilot CLI) are the script-generator AI — no SQL Server and no credentials
are needed.

1. Run **generate_scripts** with the checklist `--items`. It prints the generator system
   prompt plus one request per item.
2. For each item, follow the system prompt exactly: write the ANALYSIS, decide FEASIBLE, then
   emit the full raw response — the `FEASIBLE`/`SCRIPT_TYPE`/`SCOPE`/`SCRIPT_NAME`/
   `SCORING_LOGIC` fields and the script between `---SCRIPT_START---` and `---SCRIPT_END---`.
   Every feasible script must output `Result`, `Score`, `DatabaseQueried`, and `Finding`.
   Process the items in batches of up to 10 in parallel.
3. Save each generated item by writing its complete raw response to a file and running
   **save_generated_script** with `--id` and `--response-file`. If it reports
   `VALIDATION FAILED`, correct the script and save again (retry up to 3 times). On success it
   writes the script under `Backend/checklist/scripts/` and updates
   `Backend/checklist/deterministic-script-mapping.json` and
   `Backend/results/execution-results.json`.

## Examples

```powershell
# Evaluate two controls against a local server (Windows auth)
powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 evaluate --copilot --items 1.1.1,3.1.4 --server localhost

# Record a decision after reviewing with the user
powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 resolve_review --id 3.1.4 --decision pass --notes "SET NOCOUNT ON present in all procs"

# Generate audit scripts for two controls (no server needed), then save one
powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 generate_scripts --items 1.1.2,3.1.1
powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 save_generated_script --id 3.1.1 --response-file .\results\3.1.1.response.txt

# Show the final report
powershell -ExecutionPolicy Bypass -File tools\sql-auditor.ps1 --show-reports
```

## Notes

- The wrapper only invokes the existing CLI binary (or builds/runs the project); it does
  not change authentication, add LLM settings, or duplicate evaluation logic.
- No external LLM or API calls are introduced anywhere in the CLI.
- Requires the .NET SDK if `SQLAuditor.exe` is not already built.
- Uses relative repository paths so it works after cloning.
