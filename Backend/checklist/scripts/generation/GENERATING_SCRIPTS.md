Generating deterministic SQL scripts (operator workflow)
------------------------------------------------------

Purpose
- - -
This project keeps deterministic SQL scripts in `Backend/checklist/scripts/sql`.
Scripts must be created externally (for example, using your local GHCP Copilot),
reviewed by an operator, and then saved into the repository. The tool intentionally
disables automatic generation and runtime writes — the only approved in-tool writer
is `Auditor.SaveGeneratedScriptAsync`, which is currently wired to the (disabled)
"Generate Scripts" button and is commented for operator use.

How to author a script with GHCP Copilot
- - - - - - - - - - - - - - - - - -
1. Open `Backend/checklist/scripts/sql_template.sql` for the required format.
2. For each checklist item ID (e.g. `4.3.2`), ask GHCP Copilot to produce a
   deterministic, non-destructive SQL script that returns a single-row `Result`.
   - Use `SET NOCOUNT ON;` at the top
   - Return `Passed`, `Failed`, or `NeedsReview` literally as the `Result` value
   - Include a short comment describing assumptions and what `Passed` means

3. Save the generated SQL into a local file (naming convention suggestion:
   `<checklistId>_<short-description>.sql`) under `Backend/checklist/scripts/sql`.

How to persist via the operator UI (disabled currently)
- - - - - - - - - - - - - - - - - - - - -
When the team decides to re-enable the operator flow:
- The `Generate Scripts` button in the Frontend is the only approved writer.
- It should call `Auditor.SaveGeneratedScriptAsync(checklistId, scriptText, suggestedFileName)`
  which writes the file and updates `Backend/checklist/deterministic-script-mapping.json`.

Notes
- - -
- Do NOT enable automatic generation inside the tool (agents, evaluators, CLI).
- Prefer descriptive filenames but keep them short to avoid Windows path-length issues.
