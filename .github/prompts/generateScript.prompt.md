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
3. Use the MCP tools, not `Backend/CLI/sql-auditor.ps1` and not file-editing tools.
4. The tool serves **one batch of 10 items at a time** and defaults to **subagent mode**: it
   returns a dispatch manifest, not the scripts. Issue every `runSubagent` call it lists **in a
   single message** so the items are generated concurrently in independent sessions. Each
   `sql-script-generator` subagent owns its item's whole loop — fetching the prompt, writing the
   script, running the C1-C7 review, saving, retrying up to 3 times — and returns one status line.
5. In subagent mode do NOT write any script yourself and do NOT call
   `get_item_generation_prompt`, `validate_generated_script` or `save_generated_script`. Your job
   is to dispatch, collect the status lines, and advance the batch.
6. Only after every subagent in the batch has returned, call `generate_scripts` again with the
   **same** `items` value and the next batch number. Its header reports what was actually recorded
   for the previous batch — re-dispatch any ID shown as `NOT RECORDED`. Keep going without
   stopping until the tool reports the final batch, then call it once more to confirm the
   recorded outcome for every requested ID.
7. If subagents cannot be launched, re-request the same batch with `mode="inline"` and generate
   and save the scripts yourself, following the generator system prompt the tool returns.
8. Scripts, `deterministic-script-mapping.json` and `execution-results.json` entries for an
   ID that already has a script are **overwritten** by the tool. Regenerate those items from
   scratch — never skip them and never reuse the previous content.
9. Finish with a per-ID summary: generated (script type + scope), not feasible (reason),
   failed (last validation error), based on the tool's recorded-outcome table.
