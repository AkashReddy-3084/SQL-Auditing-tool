---
name: configure-checklist
description: Add a CUSTOM checklist item to the SQL Server governance checklist from inside VS Code, using the sql-auditor MCP server. Use for "/configureChecklist", "configure checklist", "add a custom checklist item", "add a new check for ...", "extend the audit checklist". This is checklist CONFIGURATION — it never connects to a SQL Server and never asks for credentials. Do NOT use for evaluating an instance (that is the evaluate-checklist skill) or for generating a script for an EXISTING checklist item (that is the generate-script skill).
license: MIT
---

# Configure Checklist (VS Code / MCP)

You are the **AI layer**. The `sql-auditor` MCP server makes no LLM calls — it serves the
repository's canonical prompts, runs the deterministic validators, allocates the checklist ID and
writes the files. You perform the guardrails, semantic-match and classification reviews, and the
**user** approves the generated script before anything is saved.

Use the **`configure_checklist` MCP tool**. Do **not** shell out to `tools/sql-auditor.ps1` —
that wrapper is for Copilot CLI.

> **Configuration, not evaluation.** Never call `evaluate`, never ask for a SQL Server name, a
> username or a password, and never run a generated script.

## Trigger

- `/configureChecklist`
- "configure the checklist", "add a custom checklist item", "add a check for TDE on all databases"

## What you must and must not ask for

Ask the user for exactly two things:

1. **Custom Checklist Title** — a short name for the check.
2. **Describe the Checklist Item** — what must be true for the check to pass.

**Never** ask for an Area, a Sub-area, a category or a checklist ID. The Area/Sub-area is decided
by your classification review, and the ID is allocated by the tool.

Several items can be configured in one conversation — run the whole flow once per item.

## Flow

```
Configure Checklist
  -> Guardrails
  -> Semantic Match Router
  -> Area/Sub-area Classification
  -> Script Generation
  -> User Review / Approval
  -> Save Custom Checklist + Mapping
  -> Update Final Merged Configuration
```

### 1. Open the flow

```
configure_checklist(title="<user title>", description="<user description>")
```

The tool applies a deterministic pre-screen (empty/trivial/unsafe/instruction-override requests are
refused here) and returns three canonical prompts: **guardrails**, **semantic match router** and
**Area/Sub-area classification**, together with the closest existing checklist items and the full
list of existing Areas/Sub-areas.

Perform the three reviews **in order**, using **only** those prompts. Do not substitute your own
criteria.

- **Guardrails reject** → stop. Tell the user the reason. Nothing is added.
- **Semantic match says duplicate** → stop. Show the user the **matched checklist ID and its
  text**. Do not create a duplicate.

### 2. Record the verdicts and get the ID

```
configure_checklist(
  title="<same title>", description="<same description>",
  guardrail="accept",
  match="none",                      // or the matched existing ID
  subArea="<existing sub-area id>",  // e.g. "1.1"
  rationale="<one sentence>")
```

The tool validates that the Sub-area exists, assigns the **next free ID inside it** (1.1.1–1.1.7
present → 1.1.8), and returns the generator system prompt plus the filled request for that item.
The ID is **reserved only** — the item is not in `custom-checklist.json` yet.

Report the assigned Area, Sub-area and checklist ID to the user.

### 3. Generate the script

Write the script by following the generator system prompt exactly, then:

```
configure_checklist(id="<reserved id>", response="<full raw generator output>")
```

The tool runs the deterministic format gate and returns the **C1-C7 validation prompt**. Review the
script with only those checks, then:

```
configure_checklist(id="<reserved id>", response="<same raw output>", validationVerdict="<VERDICT block>")
```

If a call returns a validation error, correct the script and submit again (up to 3 times).

### 4. User verification

The tool returns the accepted script and does **not** save it. Show the script to the user and ask
whether to add the checklist item.

```
configure_checklist(id="<reserved id>", approve=true)   // user said yes
configure_checklist(id="<reserved id>", reject=true)    // user said no — releases the ID
```

Only `approve=true` writes anything.

### 5. Confirm

Report the final merged configuration message the tool returns, then tell the user the item is now
selectable in the normal evaluation flow alongside the default checklist.

## Files

| File | Written when |
|------|--------------|
| `Backend/checklist/custom-checklist.json` | On approval — the custom item only |
| `Backend/checklist/custom-deterministic-script-mapping.json` | On approval — the script metadata only |
| `Backend/checklist/scripts/sql/<id>.sql` | On approval — the generated script |
| `Backend/checklist/master-checklist.json` | Regenerated = `default-checklist.json` + `custom-checklist.json` |
| `Backend/checklist/deterministic-script-mapping.json` | Regenerated = default mapping + custom mapping |

`default-checklist.json` and `default-deterministic-script-mapping.json` are **never modified** by
this flow.

## Reporting rules

Always give the user clear feedback for each stage:

- Guardrail rejection (with the reason)
- Duplicate / matched checklist item (with its ID and text)
- Assigned Area / Sub-area
- Generated checklist ID
- Script generation and validation status
- Their approval or rejection
- The final configuration update

## Copilot CLI equivalent

The same flow is available from Copilot CLI, one command per step:

```
sqlauditor configure_checklist --title "<t>" --description "<d>"
sqlauditor configure_checklist --title "<t>" --description "<d>" --guardrail accept --match none --sub-area 1.1 --rationale "<why>"
sqlauditor configure_checklist --id 1.1.8 --response-file <path> [--validation-file <path>]
sqlauditor configure_checklist --id 1.1.8 --approve      # or --reject
sqlauditor configure_checklist --list-sub-areas | --list
```
