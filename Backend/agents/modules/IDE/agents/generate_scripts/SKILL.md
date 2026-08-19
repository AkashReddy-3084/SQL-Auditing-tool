# Skill: generate_scripts

> Design/spec only. No code wiring yet.

## Purpose
Generate deterministic, read-only SQL/PowerShell audit scripts for one or more checklist
items directly from the IDE (VS Code Copilot Chat). This is the IDE equivalent of the WPF
"Generate Scripts" button and the CLI `generate_scripts` command, and reuses the same
generation pipeline. This is **script generation, not evaluation** — it needs no SQL Server
and no credentials.

## Trigger (intended)
- Chat/slash usage, e.g. `/generate_scripts 1.1.2,3.1.1`
- Exposed as MCP tools named `generate_scripts` and `save_generated_script` from the IDE
  host under `IDE/`.

## Inputs
| Name        | Required | Description                                                        |
|-------------|----------|--------------------------------------------------------------------|
| items       | Yes      | Comma-separated checklist IDs to generate scripts for (`1.1.2,3.1.1`). |
| checklistId | Yes†     | (save) The checklist ID the generated script belongs to.           |
| response    | Yes†     | (save) The complete raw generator output for that item.            |

† Used by `save_generated_script` after the model authors each script.

## Behavior
1. `generate_scripts` loads the checklist structure, validates requested IDs (warn + skip
   unknown IDs), and returns the generator system prompt plus one request per item.
2. Copilot Chat is the AI: for each item it writes the ANALYSIS, decides FEASIBLE, and emits
   the raw response (FEASIBLE/SCRIPT_TYPE/SCOPE/SCRIPT_NAME/SCORING_LOGIC fields plus the
   script between `---SCRIPT_START---` and `---SCRIPT_END---`). Items are processed in
   batches of up to 10 in parallel, mirroring the WPF flow.
3. `save_generated_script` validates each raw response (`ScriptOutputValidator`). On a
   validation failure it returns correction feedback so Copilot retries (up to 3 times);
   on success it writes the script and updates the mapping/results.

## Output
- Every feasible script outputs the four required fields: `Result`, `Score`,
  `DatabaseQueried`, and `Finding`.
- Scripts saved under `Backend/checklist/scripts/{sql,ps1}/<id>.<type>`.
- `Backend/checklist/deterministic-script-mapping.json` and
  `Backend/results/execution-results.json` updated per item.

## Configuration (no hardcoded secrets)
- No SQL Server and no credentials are required for generation.
- LLM provider: not used by the IDE/MCP flow (Copilot Chat is the AI); `PROVIDER_BASE_URL`,
  `PROVIDER_API_KEY`, and `MODEL` are ignored here.

## Reuses
- `SQLAuditor.Lib.ScriptGenerationSkill.LoadItemsAsync(ids)` (ID validation + item load)
- `SQLAuditor.Lib.ScriptGenerationSkill.BuildGenerationInstructions(...)` (generation prompts)
- `SQLAuditor.Lib.ScriptGenerationSkill.SaveGeneratedScriptAsync(...)` (validate + save)
- `SQLAuditor.Agents.ScriptOutputValidator`, the script-generation prompts, and the
  `ScriptGeneratorAgent` on-disk layout (scripts, mapping, execution-results).

## Out of scope
- No evaluation (never connects to a SQL Server here).
- No changes to checklist content or scoring logic.
- No new LLM providers.
