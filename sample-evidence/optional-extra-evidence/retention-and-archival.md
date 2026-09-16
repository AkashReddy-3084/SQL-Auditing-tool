# Historical / Archival Strategy — AdventureWorks Data Warehouse

> **STATUS: DRAFT — NOT APPROVED. DO NOT RELY ON THIS DOCUMENT.**
> Started after the 2026 storage review flagged unbounded growth. Never finished.

| Field | Value |
| --- | --- |
| Document version | 0.3 (draft) |
| Status | **Draft** |
| Approved by | *not submitted for approval* |
| Owner | **TBC** — previous owner M. Okafor left the organisation 2026-04-30 |
| Last touched | 2026-05-06 |
| Review cadence | not set |

## 1. Intent

Define how long history is retained in `AdventureWorks2025`, what gets archived, and what gets
purged. **None of this is agreed or implemented.**

## 2. Retention periods

| Data domain | Proposed retention | Agreed? |
| --- | --- | --- |
| `Sales.SalesOrderHeader` / `SalesOrderDetail` | 7 years? | **TODO — finance has not confirmed** |
| `Production.WorkOrder*` | 3 years? | **TODO** |
| `HumanResources.EmployeePayHistory` | unknown — legal hold may apply | **TODO — legal not consulted** |
| `Person.*` | unknown | **TODO** |
| `dbo.ErrorLog` | 90 days? | **TODO** |

## 3. Archive destination

**TODO.** Options considered but not decided:

- Cold storage on the host — rejected informally, no written rationale.
- Azure Blob archive tier — never costed.
- Do nothing and let the database grow — current de facto behaviour.

## 4. Purge mechanism

**Nothing is implemented.** There is no purge job, no retention procedure and no archival table in
`AdventureWorks2025`. The database has grown continuously since it was created and no row has ever
been archived or deleted under a retention rule.

## 5. Known gaps

- No owner. This document has had no owner since 2026-04-30.
- No approval. It has never been through change control.
- No implementation. Nothing described here exists in the database.
- Legal and finance input was never obtained, so the retention periods above are guesses.

## 6. Next steps (none scheduled)

1. Find an owner.
2. Get retention periods confirmed by finance and legal.
3. Decide an archive destination and cost it.
4. Implement and schedule a purge process.
5. Submit for approval.
