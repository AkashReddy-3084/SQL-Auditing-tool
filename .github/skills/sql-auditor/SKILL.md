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
`Backend/CLI/sql-auditor.ps1`, which locates or builds `SQLAuditor.exe` automatically.

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
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 evaluate --copilot --manual-results <last-runs|fresh> --items <ids> --server <host> [--user <name>]
  ```
  `--manual-results` is **required** and must come from the user (see step 1 below).
- **generate_report** — refresh the historical manual results and render the final outputs:
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 generate_report
  ```
- **resolve_review** — record a decision for one Needs Review item:
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 resolve_review --id <id> --decision <pass|fail|needsreview> --notes "<rationale>"
  ```
- **enrich_result** — record the audit wording you authored for one script-evaluated item:
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 enrich_result --id <id> --finding "<finding>" --evidence-file "<path>" --risk "<riskImpact>" --recommendation "<recommendation>"
  ```
  Every field also has a file form — `--finding-file`, `--evidence-file`, `--risk-file`,
  `--recommendation-file` — and `resolve_review` has `--notes-file`. **A quote character inside
  the text is eaten by the shell**, so write any field that quotes returned values (evidence,
  above all) to a file and pass the path instead of the text.
- **generate_scripts** — GENERATE audit scripts for checklist items (no LLM endpoint, no SQL Server):
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 generate_scripts --items <ids>
  ```
- **save_generated_script** — validate and save one script you generated (after generate_scripts):
  ```powershell
  powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 save_generated_script --id <id> --response-file <path-to-raw-response-file> [--validation-file <path-to-verdict-file>]
  ```
  Without `--validation-file` it prints the standard C1-C7 validation prompt and saves nothing.
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
4. Read the `=== COPILOT REVIEW REQUIRED ===` block. For **every** item listed there
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
5. Only **after** the full steps for all items have been shown, ask the user for their
   **Pass/Fail decision first** — one item at a time or all at once. The verdict is the
   reviewer's to make: never infer it, assume it, announce it, or challenge it.
6. Ask **one** follow-up question: what they inspected and what they found. Accept the
   answer as given — do not judge whether it is sufficient, do not ask for more detail, and
   do not argue for a different outcome. Re-ask only if they gave no observation at all.
7. Record the decision immediately by running **resolve_review** with `--id`, `--decision`
   (`pass`, `fail` or `notapplicable`), and `--notes` containing the user's own words. Then run
   **enrich_result** for the same item with wording *you* derive from their evidence — finding,
   evidence, riskImpact and recommendation, using only facts they stated. The reviewer's raw words
   must never be left as the report Finding.
   - Use `--decision notapplicable` when what the user reports shows the control does not exist on
     this server at all — every value absent, empty, zero or irrelevant to the item, so there is
     nothing to assess. The item is then excluded from every score, listed on the workbook's
     "Not Applicable Items" sheet and reported as **Not Applicable**, never as Pass or Fail, and it
     needs no `enrich_result` call. A zero that itself proves compliance is a Pass, not this.
8. Do not write a final summary until every review item is resolved and every script item
   is enriched. **No report has been generated at this point.** Ask the user exactly:
   "Evaluation completed. Do you want to generate the summary/report?" — and never decide for them.
   - **Yes** → run **generate_report**. It merges the newly evaluated manual results into
     `results/historical_last_run.json` (existing entries are preserved), then writes
     `results/final_report.md` and `results/audit_report.xlsx`. Then run **show_reports** and report
     **its** counts — the counts `evaluate` printed are provisional, because Not Applicable is
     decided during enrichment.
   - **No** → stop. `results/checklist_results.json` stays as it is, the historical file is not
     refreshed, and no report or workbook is written.

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
   **save_generated_script** with `--id` and `--response-file`. The first call runs the format
   gate and prints the validation system/user prompt for that script. Review the script using
   ONLY those C1-C7 checks, write your verdict to a file, and run **save_generated_script**
   again adding `--validation-file`. Use `VERDICT: VALID`, or `VERDICT: INVALID` with `ISSUES:`
   and the corrected script between `---CORRECTED_SCRIPT_START---` and
   `---CORRECTED_SCRIPT_END---`. Nothing is written to disk until a verdict is supplied. If it
   reports `VALIDATION FAILED` or `VALIDATION REJECTED`, correct the script and save again
   (retry up to 3 times). On success it writes the script under
   `Backend/checklists/Scripts/` and updates
   `Backend/checklists/deterministic-script-mapping.json` and
   `Backend/results/execution-results.json`.

## Examples

```powershell
# Evaluate two controls against a local server (Windows auth, fresh manual evaluation)
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 evaluate --copilot --manual-results fresh --items 1.1.1,3.1.4 --server localhost

# Re-run reusing the manual results recorded by the previous audit
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 evaluate --copilot --manual-results last-runs --items 1.1.1,3.1.4 --server localhost

# Record a decision after reviewing with the user
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 resolve_review --id 3.1.4 --decision pass --notes "SET NOCOUNT ON present in all procs"

# Generate audit scripts for two controls (no server needed), then save one
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 generate_scripts --items 1.1.2,3.1.1
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 save_generated_script --id 3.1.1 --response-file .\results\3.1.1.response.txt
powershell -ExecutionPolicy Bypass -File Backend\CLI\sql-auditor.ps1 save_generated_script --id 3.1.1 --response-file .\results\3.1.1.response.txt --validation-file .\results\3.1.1.verdict.txt

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
