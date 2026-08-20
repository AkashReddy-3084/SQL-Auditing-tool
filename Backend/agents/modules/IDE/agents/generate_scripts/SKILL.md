# Skill: generate_scripts

> Wired: exposed as the `generate_scripts`, `validate_generated_script` and
> `save_generated_script` MCP tools in `IDE/AuditTools.cs`, and surfaced in VS Code as the
> `/generateScript` command (`.github/prompts/generateScript.prompt.md`) backed by the
> `.github/skills/generate-script` skill.

## Purpose
Generate deterministic, read-only SQL/PowerShell audit scripts for one or more checklist
items directly from the IDE (VS Code Copilot Chat). This is the IDE equivalent of the WPF
"Generate Scripts" button and the CLI `generate_scripts` command, and reuses the same
generation pipeline. This is **script generation, not evaluation** — it needs no SQL Server
and no credentials.

## Trigger (intended)
- VS Code slash command `/generateScript 1.1.2` or `/generateScript 1.1.1 - 2.1.4`, backed by
  `.github/prompts/generateScript.prompt.md` and the `.github/skills/generate-script` skill.
- Chat/slash usage, e.g. `/generate_scripts 1.1.2,3.1.1`
- Exposed as MCP tools named `generate_scripts` and `save_generated_script` from the IDE
  host under `IDE/`.

## Inputs
| Name        | Required | Description                                                        |
|-------------|----------|--------------------------------------------------------------------|
| items       | Yes      | Checklist IDs: single (`1.1.2`), list (`1.1.2,3.1.1`) or inclusive range in checklist order (`1.1.1 - 2.1.4`). |
| batch       | No       | 1-based batch number (10 items per batch). Defaults to 1; pass the same `items` with `batch+1` for the next batch. |
| checklistId | Yes†     | (save) The checklist ID the generated script belongs to.           |
| response    | Yes†     | (save) The complete raw generator output for that item.            |
| validationVerdict | Yes† | (save) The C1-C7 verdict. Omit on the first call to receive the validation prompt. |

† Used by `save_generated_script` after the model authors each script.

## Prompt templates (mandatory)
Every stage runs on the standard templates in `Backend/agents/prompts/`; the host never
substitutes its own reasoning. A missing or empty template is a hard error.

| Stage      | System                          | User                          |
|------------|---------------------------------|-------------------------------|
| Generation | `script_generator_system.txt`   | `script_generator_user.txt`   |
| Validation | `script_validation_system.txt`  | `script_validation_user.txt`  |

## Behavior
1. `generate_scripts` loads the checklist structure and expands `items` into concrete IDs,
   sorted in checklist order. A range is resolved by *position* in `master-checklist.json`,
   not by numeric comparison, so `1.1.1 - 2.1.4` means every item between those two entries.
   Unresolvable IDs are reported and skipped.
2. The resolved list is served in batches of 10 (`GenerationBatchSize`, matching
   `ScriptGeneratorAgent.RunAsync`). One call returns the generator system prompt plus the
   per-item requests for **that batch only**, notes which IDs already have a script (they are
   overwritten on save), and prints the exact next call:
   `generate_scripts(items="<same value>", batch=<n+1>)`. Calling past the last batch returns
   an "all batches complete" message instead of prompts.
3. Copilot Chat is the AI: for each item in the batch it writes the ANALYSIS, decides
   FEASIBLE, and emits the raw response (FEASIBLE/SCRIPT_TYPE/SCOPE/SCRIPT_NAME/SCORING_LOGIC
   fields plus the script between `---SCRIPT_START---` and `---SCRIPT_END---`). The batch is
   generated in parallel and fully saved before the next batch is requested, mirroring the
   WPF flow.
4. `save_generated_script` runs the deterministic gate (`ScriptOutputValidator`), then —
   when no verdict was supplied — returns the filled validation prompts and saves nothing.
   `validate_generated_script` returns that same review request on demand.
5. Copilot performs the C1-C7 review using only those templates and calls
   `save_generated_script` again with the verdict. `VERDICT: VALID` saves; `VERDICT: INVALID`
   with a corrected script re-runs the format gate against the correction and then saves;
   `VERDICT: INVALID` without one is rejected (retry up to 3 times). A reply with no
   `VERDICT:` line is rejected so free-form review cannot bypass the templates.

## Output
- Every feasible script outputs the four required fields: `Result`, `Score`,
  `DatabaseQueried`, and `Finding`.
- Scripts saved under `Backend/checklist/scripts/{sql,ps1}/<id>.<type>`.
- `Backend/checklist/deterministic-script-mapping.json` and
  `Backend/results/execution-results.json` updated per item.
- Re-generating an ID **overwrites** its script file and replaces its mapping and
  execution-results entries, as in the WPF app.

## Configuration (no hardcoded secrets)
- No SQL Server and no credentials are required for generation.
- LLM provider: not used by the IDE/MCP flow (Copilot Chat is the AI); `PROVIDER_BASE_URL`,
  `PROVIDER_API_KEY`, and `MODEL` are ignored here.

## Reuses
- `SQLAuditor.Lib.ScriptGenerationSkill.LoadItemsAsync(ids)` (ID validation + item load)
- `SQLAuditor.Lib.ScriptGenerationSkill.BuildGenerationInstructions(...)` (generation prompts)
- `SQLAuditor.Lib.ScriptGenerationSkill.BuildValidationInstructions(...)` (validation prompts)
- `SQLAuditor.Lib.ScriptGenerationSkill.SaveGeneratedScriptAsync(...)` (validate + save)
- `SQLAuditor.Agents.ScriptOutputValidator`, `ChecklistItemProcessor.ParseValidationResponse`,
  the four prompt templates, and the `ScriptGeneratorAgent` on-disk layout (scripts, mapping,
  execution-results).

## Out of scope
- No evaluation (never connects to a SQL Server here).
- No changes to checklist content or scoring logic.
- No new LLM providers.
