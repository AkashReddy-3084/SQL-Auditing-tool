---
name: generate-script
description: Generate deterministic, read-only SQL Server audit scripts for checklist items from inside VS Code, using the sql-auditor MCP server. Use for "/generateScript <id>", "/generateScript <startId> - <endId>", "generate script for checklist 1.1.2", "create audit scripts for 1.1.1 to 2.1.4", "write audit scripts for these checklist items". This is script GENERATION, not evaluation — it never connects to a SQL Server and never asks for credentials. Do NOT use for auditing/evaluating an instance (that is the sql-auditor skill).
license: MIT
---

# Generate Script (VS Code / MCP)

You (GitHub Copilot in VS Code) are the **script-generator AI**. The `sql-auditor` MCP
server holds no model of its own — it serves the repository's canonical prompt templates,
runs the deterministic validators and writes the files. Everything the WPF "Generate
Scripts" button does through the configured LLM, you do here through the MCP tools.

Use the **MCP tools** for this skill. Do **not** shell out to `tools/sql-auditor.ps1` —
that wrapper is for Copilot CLI, and running it from the IDE bypasses the MCP flow.

> **This is generation, not evaluation.** Never call `evaluate`, never ask for a SQL Server
> name, a username or a password, and never run any generated script.

## Trigger

- `/generateScript 1.1.2` — one checklist item
- `/generateScript 1.1.1 - 2.1.4` — every item between the two IDs, in checklist order
- `/generateScript 1.1.2,3.1.1,4.2.6` — an explicit list
- Any natural-language request to generate/create/write audit scripts for checklist IDs

Pass whatever the user typed straight through as the `items` argument — the tool parses
single IDs, comma-separated lists and ranges itself. Only ask a question if no ID at all
was supplied.

## Tools (sql-auditor MCP server)

| Tool | Use |
|------|-----|
| `generate_scripts` | Resolves the IDs, returns the generator system prompt + the per-item requests for **one batch of 10** |
| `save_generated_script` | Format gate → returns the C1-C7 validation prompt → saves once a verdict is supplied |
| `validate_generated_script` | Returns the same C1-C7 review request on demand |
| `load_checklist` | Look up valid IDs when the user's input cannot be resolved |

## Workflow

### 1. Start the first batch

Call `generate_scripts(items="<user input verbatim>", batch=1)`.

The tool returns:
- the resolved ID list, in checklist order, and the total batch count;
- any IDs that do not exist (reported and skipped — mention them, do not invent them);
- which IDs already have a script (they **will be overwritten** — regenerate them from
  scratch, never skip them and never reuse the old content);
- the **generator system prompt** (`script_generator_system.txt`) and one filled
  **per-item request** (`script_generator_user.txt`) for the items in this batch.

### 2. Generate every item in the batch

Mirror `ScriptGeneratorAgent.RunAsync`: work the **whole batch** before saving anything to
the next one, treating each item independently.

For each item in the batch:
1. Write the short **ANALYSIS** the user prompt asks for.
2. Apply the **documentation gate first**, then the artifact gate, and decide `FEASIBLE`.
3. Emit the complete raw response in exactly the format the system prompt defines — the
   `FEASIBLE` / `SCRIPT_TYPE` / `SCOPE` / `SCRIPT_NAME` / `SCORING_LOGIC` fields and the
   script between `---SCRIPT_START---` and `---SCRIPT_END---`, with no markdown fences
   inside the markers.
4. Every feasible script must be strictly read-only and end with the four-column output:
   `Result`, `Score`, `DatabaseQueried`, `Finding`.

`FEASIBLE: NO` is a valid outcome: pass that response to `save_generated_script` too — it
is recorded as *Not Feasible* in the mapping and execution results, and no file is written.

### 3. Save + validate each item (per item, still inside the batch)

1. `save_generated_script(checklistId="<id>", response="<the COMPLETE raw output>")`.
   This runs the deterministic format gate (`ScriptOutputValidator`) and, when it passes,
   returns the **validation system prompt** and the filled validation request. **Nothing is
   written to disk yet.**
2. Review the script using **only** the C1-C7 checks in that returned prompt. Do not
   substitute your own criteria and do not re-run the generator prompt.
3. `save_generated_script(checklistId="<id>", response="<the same raw output>", validationVerdict="<verdict>")`
   - `VERDICT: VALID` — saves the script.
   - `VERDICT: INVALID` plus `ISSUES:` and the corrected script between
     `---CORRECTED_SCRIPT_START---` and `---CORRECTED_SCRIPT_END---` — the correction is
     re-gated and then saved.
   - A reply with no `VERDICT:` line is rejected and nothing is saved.
4. On `VALIDATION FAILED`, `VALIDATION REJECTED` or `CORRECTED SCRIPT STILL INVALID`,
   correct the script and save again — **up to 3 attempts per item**, like the pipeline's
   retry loop. After 3 failures, record the item as failed and move on.

### 4. Advance to the next batch

Only once **every** item in the current batch is saved (or recorded as not feasible or
failed), call the next batch exactly as the tool's footer states:

```
generate_scripts(items="<the SAME items value>", batch=<n+1>)
```

Keep `items` byte-for-byte identical across batches so the batching stays aligned. Do not
stop, summarise or ask the user anything between batches — continue until the tool reports
the final batch.

### 5. Report

After the final batch, report per-ID totals: **generated** (with script type and scope),
**not feasible** (with the reason), and **failed** (with the last validation error). State
which files were written.

## What gets written

| Path | Content |
|------|---------|
| `Backend/checklist/scripts/sql/<id>.sql` or `.../ps1/<id>.ps1` | The generated script (overwritten if it exists) |
| `Backend/checklist/deterministic-script-mapping.json` | `script_file`, `IsAdminCheck`, `IsDocumentationCheck`, `MCP_Feasibility` for the ID (entry replaced) |
| `Backend/results/execution-results.json` | The `Script Generated` / `Not Feasible` entry for the ID (entry replaced) |

Overwrite is the intended behaviour and is handled by the tool — never edit these files by
hand and never write scripts with file-editing tools.

## Rules

- Batches are **10 items**, matching `ScriptGeneratorAgent.RunAsync`. Never take a bigger
  batch and never save one item at a time across batch boundaries.
- The prompt templates in `Backend/agents/prompts/` are the only source of the generation
  and validation rules. If a template is missing the tool errors — surface that, do not
  improvise a replacement.
- No LLM configuration is involved: `PROVIDER_BASE_URL`, `PROVIDER_API_KEY` and `MODEL` are
  irrelevant here. Never ask the user for them.
- Do not modify the checklist, the scoring rubric or any evaluation code.

## Reference implementation

- `Backend/agents/modules/ScriptGeneratorAgent.cs` — batch-of-10 orchestration, retries, persistence
- `Backend/agents/modules/ChecklistItemProcessor.cs` — response and verdict parsing
- `Backend/agents/modules/ScriptOutputValidator.cs` — deterministic format/read-only gate
- `Backend/agents/modules/application/ScriptGenerationSkill.cs` — the shared skill the MCP tools call
- `Backend/agents/modules/IDE/AuditTools.cs` — the MCP tool definitions
- `Backend/agents/prompts/script_generator_{system,user}.txt`, `script_validation_{system,user}.txt`
