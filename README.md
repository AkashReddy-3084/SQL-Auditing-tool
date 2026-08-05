# SQL Auditor (prototype)

Lightweight console app to run deterministic SQL audit scripts located in the repository's `Backend/checklist/scripts/sql` folder.

High-level architecture and flow documentation: see `ARCHITECTURE.md`.

Build:

```bash
dotnet build "sql-auditor/SQLAuditor.csproj"
```

Run (interactive):

```bash
dotnet run --project "sql-auditor/SQLAuditor.csproj"
```

The app will prompt for the target FQDN and auth method, then run scripts and write outputs to a `results/` folder.

