Generating deterministic SQL scripts (operator workflow)
------------------------------------------------------

Purpose
- - -
This project keeps deterministic SQL scripts in `Backend/checklists/Scripts/sql`.
Scripts for the default checklist are authored externally (for example, using your local
GHCP Copilot), reviewed by an operator, and then saved into the repository. There is no
standalone in-tool generator: the only in-tool writer is the **Configure Checklist** flow,
and it writes a script only for the ONE new custom checklist item it reserves. Existing and
default checklist items are never regenerated.

How to author a script with GHCP Copilot
- - - - - - - - - - - - - - - - - -
1. Open `Backend/Modules/generate_scripts/tools/sql_template.sql` for the required format.
2. For each checklist item ID (e.g. `4.3.2`), ask GHCP Copilot to produce a
   deterministic, non-destructive SQL script that returns a single-row `Result`.
   - Use `SET NOCOUNT ON;` at the top
   - Return `Passed`, `Failed`, or `NeedsReview` literally as the `Result` value
   - Include a short comment describing assumptions and what `Passed` means

3. Save the generated SQL into a local file (naming convention suggestion:
   `<checklistId>_<short-description>.sql`) under `Backend/checklists/Scripts/sql`.

How new custom checklist items get their scripts
- - - - - - - - - - - - - - - - - - - - -
- The **Add New Custom Checklist Item** flow (WPF), the `configure_checklist` MCP tool (IDE)
  and the `configure_checklist` CLI subcommand all run the same pipeline.
- It generates, format-gates and C1-C7 reviews the script for the newly reserved ID, then
  writes it and updates `custom-deterministic-script-mapping.json` plus the merged
  `deterministic-script-mapping.json` — only after the user approves.

Notes
- - -
- Do NOT enable automatic generation inside the tool (agents, evaluators, CLI).
- Prefer descriptive filenames but keep them short to avoid Windows path-length issues.
