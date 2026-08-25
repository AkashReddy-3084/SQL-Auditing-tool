---
mode: agent
description: Evaluate a SQL Server instance against one checklist item, a range of items or the whole checklist, using the sql-auditor MCP server.
---

# /evaluate

Evaluate the checklist item(s) the user named in this request against their SQL Server instance.

Usage the user may have typed:
- `/evaluate 1.1.2` — a single checklist item
- `/evaluate 1.1.1 - 2.1.4` — every item between those two IDs, in checklist order
- `/evaluate 1.1.2,3.1.1,4.2.6` — an explicit list
- `/evaluate all` — the whole checklist

Follow the repository skill `.github/skills/evaluate-checklist/SKILL.md` exactly. In short:

1. This is **evaluation, not script generation**. Do NOT call `generate_scripts` or
   `save_generated_script`.
2. Take the text the user typed after the command **verbatim** as the `items` argument and call
   the `evaluate` tool on the `sql-auditor` MCP server. The tool resolves single IDs, lists,
   ranges and `all` itself — do not pre-expand them and do not reformat them.
3. `evaluate` returns the exact next question whenever an input is missing. Ask it, then call
   `evaluate` again with the answer plus everything gathered so far. **Never guess the server
   name** and **never ask for a password in chat** — for SQL Login the tool needs only the
   username; the password is read from `SQLAUDITOR_SQL_PASSWORD` in the session that launched
   VS Code.
4. Use the MCP tools, not `tools/sql-auditor.ps1` and not file-editing tools.
5. This server makes **no LLM calls — you are the AI layer.** For every item in the
   `=== COPILOT ENRICHMENT REQUIRED ===` block, author `finding`, `evidence`, `riskImpact` and
   `recommendation` from the `Script result` shown there and record them with `enrich_result`.
   Use only the facts it contains. Never change Outcome, Score, Severity or Databases Verified.
6. When the `Script result` holds no supporting artefact at all (every value NULL, empty, zero or
   "not found"), start the evidence with the exact words `Not Applicable.` plus one sentence of
   your own reasoning. The tool then re-stamps the item to Outcome `N/A` and excludes it from
   every score — report it as **Not Applicable**, never as Pass or Fail. A zero that itself
   proves compliance is real evidence, not "Not Applicable".
7. For every item in the `=== COPILOT REVIEW REQUIRED ===` block you are the reviewer: print the
   full verification guidance for all items first, then ask for the user's Pass/Fail decision,
   then one follow-up for what they inspected. Record it with `resolve_review`, then call
   `enrich_result` for the same item with wording you derive from their evidence.
8. The counts `evaluate` prints are **provisional** — N/A is decided during enrichment. Do not
   present them as the result. When every item is enriched and reviewed, call `show_reports` and
   report ITS counts.
