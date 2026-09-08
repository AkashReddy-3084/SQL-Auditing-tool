---
mode: agent
description: Add a custom checklist item under an existing Area/Sub-area, using the sql-auditor MCP server. Configuration only — never evaluation.
---

# /configureChecklist

Add a **custom checklist item** to the SQL Server governance checklist.

Follow the repository skill `.github/skills/configure-checklist/SKILL.md` exactly. In short:

1. This is **checklist configuration, not evaluation and not script generation for an existing
   item**. Do NOT call `evaluate` or `generate_scripts`, do NOT connect to a SQL Server, and do
   NOT ask for a server name, username or password.
2. Ask the user for exactly two things: the **Custom Checklist Title** and a **description of the
   checklist item**. Never ask for an Area, a Sub-area, a category or a checklist ID — the
   classification review and the tool decide those.
3. Call `configure_checklist(title=..., description=...)`. It pre-screens the request and returns
   the canonical **guardrails**, **semantic match router** and **Area/Sub-area classification**
   prompts, the closest existing checklist items, and every valid Sub-area. Perform the three
   reviews in that order using ONLY those prompts.
4. Stop and report if either gate fails:
   - **Guardrails reject** → tell the user why. Nothing is added.
   - **Duplicate** → show the matched checklist **ID and its text**. Nothing is added.
5. Otherwise call `configure_checklist` again with `guardrail="accept"`, `match` (the matched ID
   or `"none"`), `subArea` (an existing Sub-area ID) and `rationale`. Report the assigned Area,
   Sub-area and checklist ID.
6. Write the script from the generator prompt the tool returns, then submit it with
   `configure_checklist(id=..., response=...)`, perform the C1-C7 review it returns, and submit
   again with `validationVerdict=...`. Correct and resubmit on a validation error (up to 3 times).
7. **Show the generated script to the user** and ask whether to add the checklist item. Call with
   `approve=true` only after they say yes, or `reject=true` if they say no. Nothing is written to
   `custom-checklist.json` or `custom-deterministic-script-mapping.json` before approval, and the
   default checklist and default mapping are never modified.
8. Finish by reporting every stage: guardrail outcome, duplicate/matched item, assigned
   Area/Sub-area, generated checklist ID, script generation and validation status, the user's
   approval or rejection, and the final merged configuration update.

Use `configure_checklist(listSubAreas=true)` to show the valid Areas/Sub-areas and
`configure_checklist(listPending=true)` to show drafts that are reserved but not yet approved.
