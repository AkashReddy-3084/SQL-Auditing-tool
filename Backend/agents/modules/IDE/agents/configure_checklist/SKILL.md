# Skill: configure_checklist

> Wired: exposed as the `configure_checklist` MCP tool and the `configure_checklist` MCP prompt in
> `IDE/AuditTools.cs`, as the `sqlauditor configure_checklist` CLI subcommand in
> `Backend/core/Program.cs`, and as the **Configure Checklist** button on the WPF Login page.
> The VS Code skill is `.github/skills/configure-checklist`.

## Purpose
Add a **custom checklist item** under an **existing** Area/Sub-area, without modifying the default
checklist or the default script mapping. This is the IDE/CLI equivalent of the WPF
"Configure Checklist" → "Add Configure Checklist" → "Custom Checklist Progress" pages, and reuses
the same guardrails, semantic match, classification, script generation and persistence code
(`CustomChecklistHostFlow` → `CustomChecklistSkill` → `ChecklistConfigurationStore`).

This is **configuration, not evaluation** — it needs no SQL Server and no credentials.

## Trigger (intended)
- VS Code MCP prompt `/configure_checklist`, backed by the `.github/skills/configure-checklist` skill.
- Copilot CLI: `sqlauditor configure_checklist ...`
- Natural language: "add a custom checklist item", "configure the checklist".

## Inputs
| Name              | Required | Description |
|-------------------|----------|-------------|
| title             | Step 1/2 | Custom Checklist Title, from the user. |
| description       | Step 1/2 | Description of the checklist item, from the user. |
| guardrail         | Step 2   | `accept` or `reject`, from the guardrails review. |
| guardrailReason   | Step 2   | Reason shown to the user on rejection. |
| match             | Step 2   | The duplicated existing checklist ID, or `none`. |
| matchReason       | Step 2   | Reason from the semantic match review. |
| subArea           | Step 2   | An **existing** Sub-area ID, e.g. `1.1`. New Areas/Sub-areas are not supported. |
| rationale         | Step 2   | Why that Sub-area is the right home. |
| id                | Step 3/4 | The reserved checklist ID returned by step 2. |
| response          | Step 3   | The complete raw generator output. |
| validationVerdict | Step 3   | The C1-C7 verdict; omit on the first pass to receive the prompt. |
| approve / reject  | Step 4   | The user's decision. |

The Area/Sub-area and the checklist ID are **never supplied by the user**.

## Pipeline
1. **Deterministic pre-screen** — empty, trivial, unsafe (state-changing) or instruction-override
   requests are refused before any review.
2. **Guardrails** — `custom_checklist_guardrails_system.txt` / `_user.txt`.
3. **Semantic Match Router** — `custom_checklist_match_system.txt` / `_user.txt`, over a token-overlap
   shortlist of the closest existing default and custom items.
4. **Area/Sub-area Classification** — `custom_checklist_classify_system.txt` / `_user.txt`, restricted
   to the Sub-areas that already exist in `default-checklist.json`.
5. **ID allocation** — next free number inside the chosen Sub-area, reserved under a cross-process
   mutex so two concurrent additions cannot receive the same ID.
6. **Script generation** — the existing `script_generator_*` prompts, `ScriptOutputValidator` format
   gate and `script_validation_*` C1-C7 review.
7. **User approval** — the script is shown and held; nothing is written until the user approves.
8. **Persistence + merge** — see below.

## Outputs
| File | Effect |
|------|--------|
| `Backend/checklist/custom-checklist.json` | The approved item is appended under its Area/Sub-area. |
| `Backend/checklist/custom-deterministic-script-mapping.json` | `script_file`, `scope`, `IsAdminCheck`, `IsDocumentationCheck`, `MCP_Feasibility` for the new ID. |
| `Backend/checklist/scripts/sql/<id>.sql` | The approved script (when one is feasible). |
| `Backend/checklist/master-checklist.json` | Regenerated: `default-checklist.json` + `custom-checklist.json`. |
| `Backend/checklist/deterministic-script-mapping.json` | Regenerated: default mapping + custom mapping. |
| `Backend/results/execution-results.json` | Generation outcome for the new ID. |
| `Backend/checklist/custom-checklist-pending.json` | Reserved-but-unapproved drafts; entries are removed on approval or rejection. |

`default-checklist.json` and `default-deterministic-script-mapping.json` are created once from the
existing runtime files and are never modified by this flow.

## Guarantees
- Rejected, duplicate and unapproved items are never written to the custom configuration.
- New Areas/Sub-areas are never created.
- The merged runtime files stay schema-compatible with the existing evaluation, reporting and
  historical-manual-results flows, and existing checklist IDs are unchanged.
