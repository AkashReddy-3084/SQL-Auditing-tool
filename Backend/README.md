Backend folder layout.

- `Application/core`: audit engine (`Auditor`), run output paths, provider and prompt
  infrastructure, and the `SQLAuditor.Lib` project every host references.
- `Modules/evaluate`: the three evaluation techniques (`Script`, `AI-MCP`, `AI-Manual`) plus the
  outcome rules and result enrichment they share.
- `Modules/generate_scripts`: generation pipeline, its models, prompts and authoring tools.
- `Modules/show_results`: Markdown and Excel report generation.
- `CLI`: console host (`SQLAuditor.exe`) and the `sql-auditor.ps1` launcher.
- `IDE`: MCP server for VS Code, with one `SKILL.md` per exposed tool.
- `checklists`: master checklist, deterministic script mapping, and `Scripts/{sql,ps1}`.

Each module owns its own `prompts/` folder. `SQLAuditor.Lib` compiles `Modules/**`, so a module has
exactly one implementation, shared by the WPF, CLI and MCP hosts.
