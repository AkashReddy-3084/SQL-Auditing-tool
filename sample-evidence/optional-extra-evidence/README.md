# Optional extra evidence

Documents kept **outside** the attached evidence set on purpose.

`retention-and-archival.md` covers checklist item **1.2.7 Historical/archival strategy**. It is held
back so that 1.2.7 has no supporting artefact and falls through to manual review, which exercises
the Needs Review path.

Copy it into the evidence folder when you want 1.2.7 to be judged instead:

```powershell
Copy-Item "sample-evidence\optional-extra-evidence\retention-and-archival.md" "sample-evidence\adventureworks-dw-docs\data-warehouse\" -Force
```

It is an unapproved version 0.3 draft with no owner and nothing implemented, so the expected verdict
once attached is **Fail**, not Pass.
