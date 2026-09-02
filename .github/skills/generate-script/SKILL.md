---
name: generate-script
description: Generate deterministic, read-only SQL Server audit scripts for checklist items from inside VS Code, using the sql-auditor MCP server. Use for "/generateScript <id>", "/generateScript <startId> - <endId>", "generate script for checklist 1.1.2", "create audit scripts for 1.1.1 to 2.1.4", "write audit scripts for these checklist items". This is script GENERATION, not evaluation — it never connects to a SQL Server and never asks for credentials. Do NOT use for auditing/evaluating an instance (that is the sql-auditor skill).
license: MIT
---

# Generate Script (VS Code / MCP)

You are the **orchestrator**. The `sql-auditor` MCP server makes no LLM calls — it serves the
repository's canonical prompts, runs the deterministic validators and writes the files. The
scripts themselves are written by `sql-script-generator` subagents, one per checklist item, so
each item gets its own isolated session exactly as the WPF app gives each item its own LLM
request.

Use the **MCP tools**. Do **not** shell out to `Backend/CLI/sql-auditor.ps1` — that wrapper is for
Copilot CLI and bypasses this flow.

> **Host check — do this first.** This skill requires the `generate_scripts`,
> `get_item_generation_prompt`, `validate_generated_script` and `save_generated_script` tools of the
> `sql-auditor` MCP server. If they are **not** available in the session (you are running in
> **GitHub Copilot CLI**, or the server has not been started in VS Code), do **not** stop: switch to
> the `sql-auditor` skill (`.github/skills/sql-auditor/SKILL.md`) and use its `generate_scripts` /
> `save_generated_script` commands through `Backend/CLI/sql-auditor.ps1`.

> **Generation, not evaluation.** Never call `evaluate`, never ask for a SQL Server name, a
> username or a password, and never run a generated script.

## Trigger

- `/generateScript 1.1.2` — one checklist item
- `/generateScript 1.1.1 - 2.1.4` — every item between the two IDs, in checklist order
- `/generateScript 1.1.2,3.1.1,4.2.6` — an explicit list
- Any natural-language request to generate/create/write audit scripts for checklist IDs

Pass whatever the user typed straight through as the `items` argument — the tool parses
single IDs, comma-separated lists and ranges itself. Only ask a question if no ID at all
was supplied.

## Tools

| Tool | Used by | Purpose |
|------|---------|---------|
| `generate_scripts` | orchestrator | Resolves the IDs, serves **one batch of 10**, returns the dispatch manifest |
| `runSubagent` | orchestrator | Launches `sql-script-generator`, one per item |
| `get_item_generation_prompt` | **subagent only** | The single-item generator prompt |
| `save_generated_script` | **subagent only** | Format gate → C1-C7 prompt → save |
| `load_checklist` | orchestrator | Look up valid IDs when the user's input cannot be resolved |

## Workflow

### 1. Open the first batch

```
generate_scripts(items="<user input verbatim>", batch=1)
```

Subagent mode is the default. The tool returns the resolved ID list in checklist order, the
total batch count, any unresolvable IDs, which IDs already have a script and **will be
overwritten**, and the exact `runSubagent` calls for this batch.

### 2. Fan out — one subagent per item

Issue **all** the `runSubagent` calls the tool listed **in a single message**, so they run
concurrently in independent sessions:

```
runSubagent(agentName="sql-script-generator", description="Generate script <id>",
            prompt="Generate and save the SQL Auditor audit script for checklist item <id>. ...")
```

Each subagent owns its item's entire loop — fetch prompt, author the response, format gate,
C1-C7 review, save, retry up to 3 times — and returns one status line.

**In subagent mode you must not** call `get_item_generation_prompt`,
`validate_generated_script` or `save_generated_script`, and you must not write any script
yourself. Dispatch, collect, advance — that is the whole job.

### 3. Collect and advance

Wait for every subagent in the batch to return. Then call the next batch with the **same**
`items` value:

```
generate_scripts(items="<same value>", batch=<n+1>)
```

Its header reports what `execution-results.json` actually recorded for the **previous** batch.
Any ID shown as `NOT RECORDED` never reached `save_generated_script` — re-dispatch a subagent
for that single ID before continuing.

Do not stop, summarise or ask anything between batches. Keep going until the tool reports the
final batch, then call it once more (`batch = total + 1`) to get the recorded outcome for every
requested ID.

### 4. Report

Per-ID totals: **generated** (script type and scope), **not feasible** (reason), **failed**
(last error). Base this on the tool's recorded-outcome table, not only on what the subagents
claimed.

## Inline fallback

If subagents cannot be launched — `runSubagent` unavailable, the agent file not picked up, or
dispatch fails — re-request the **same batch** with `mode="inline"`:

```
generate_scripts(items="<same value>", batch=<same>, mode="inline")
```

That returns the generator system prompt plus every per-item request, and you author and save
the scripts in this conversation: for each item write the ANALYSIS, decide FEASIBLE, emit the
raw response, call `save_generated_script` (format gate), perform the C1-C7 review using only
those checks, call it again with the verdict, retrying up to 3 times. Keep `mode="inline"` on
the remaining batches so the run stays consistent. Inline mode is also reasonable for a 1-3
item request you want to watch.

## What gets written

| Path | Content |
|------|---------|
| `Backend/checklists/Scripts/sql/<id>.sql` or `.../ps1/<id>.ps1` | The generated script (overwritten if it exists) |
| `Backend/checklists/deterministic-script-mapping.json` | `script_file`, `IsAdminCheck`, `IsDocumentationCheck`, `MCP_Feasibility` for the ID (entry replaced) |
| `Backend/results/execution-results.json` | The `Script Generated` / `Not Feasible` entry for the ID (entry replaced) |

Overwrite is the intended behaviour and is handled by the tool — never edit these files by
hand and never write scripts with file-editing tools. Writes are serialised inside the MCP
server, so parallel subagents cannot corrupt them.

## Rules

- **One batch of 10 at a time**, matching `ScriptGeneratorAgent.RunAsync`. Never dispatch two
  batches at once and never take a bigger batch.
- The prompt templates in `Backend/Modules/generate_scripts/prompts/` are the only source of the generation
  and validation rules. If a template is missing the tool errors — surface that, do not
  improvise a replacement.
- No LLM configuration is involved: `PROVIDER_BASE_URL`, `PROVIDER_API_KEY` and `MODEL` are
  irrelevant here. Never ask the user for them.
- Do not modify the checklist, the scoring rubric or any evaluation code.

## Reference implementation

- `Backend/Modules/generate_scripts/ScriptGeneratorAgent.cs` — batch-of-10 orchestration, retries, persistence
- `Backend/Modules/generate_scripts/ChecklistItemProcessor.cs` — response and verdict parsing
- `Backend/Modules/generate_scripts/ScriptOutputValidator.cs` — deterministic format/read-only gate
- `Backend/Modules/generate_scripts/ScriptGenerationSkill.cs` — the shared skill the MCP tools call
- `Backend/IDE/AuditTools.cs` — the MCP tool definitions
- `.github/agents/sql-script-generator.agent.md` — the per-item subagent contract
- `Backend/Modules/generate_scripts/prompts/script_generator_{system,user}.txt`, `script_validation_{system,user}.txt`
