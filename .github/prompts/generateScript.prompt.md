---
mode: agent
description: Generate deterministic read-only SQL audit scripts for one checklist item or a range of checklist items, using the sql-auditor MCP server.
---

# /generateScript

Generate audit scripts for the checklist item(s) the user named in this request.

Usage the user may have typed:
- `/generateScript 1.1.2` — a single checklist item
- `/generateScript 1.1.1 - 2.1.4` — every item between those two IDs, in checklist order
- `/generateScript 1.1.2,3.1.1,4.2.6` — an explicit list

Follow the repository skill `.github/skills/generate-script/SKILL.md` exactly. In short:

1. This is **script generation, not evaluation**. Do NOT call the `evaluate` tool, do NOT
   connect to a SQL Server, and do NOT ask for a server name, username or password.
2. Take the text the user typed after the command **verbatim** as the `items` argument and
   call the `generate_scripts` tool on the `sql-auditor` MCP server with `batch=1`. The tool
   parses single IDs, comma-separated lists and ranges itself — do not pre-expand them and
   do not reformat them. Only ask a question if no checklist ID was supplied at all.
3. Use the MCP tools, not `tools/sql-auditor.ps1` and not file-editing tools.
4. The tool serves the items in **batches of 10**, mirroring the WPF Generate Scripts flow.
   For the current batch: generate every item (ANALYSIS → FEASIBLE → the raw response with
   the `---SCRIPT_START---` / `---SCRIPT_END---` markers) following the generator system
   prompt the tool returned.
5. Save each item with `save_generated_script`. The first call runs the format gate and
   returns the C1-C7 validation prompt without saving; review the script using only those
   checks and call `save_generated_script` again with the verdict. Correct and retry up to
   3 times on a validation failure.
6. Only after every item in the batch is saved (or recorded as not feasible/failed), call
   `generate_scripts` again with the **same** `items` value and the next batch number.
   Keep going without stopping until the tool reports the final batch.
7. Scripts, `deterministic-script-mapping.json` and `execution-results.json` entries for an
   ID that already has a script are **overwritten** by the tool. Regenerate those items from
   scratch — never skip them and never reuse the previous content.
8. Finish with a per-ID summary: generated (script type + scope), not feasible (reason),
   failed (last validation error).
