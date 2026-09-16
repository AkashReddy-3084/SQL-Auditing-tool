# Maintenance Windows and Patching Approach — AdventureWorks Data Platform

| Field | Value |
| --- | --- |
| Document version | 3.4 |
| Status | **Approved** |
| Approved by | Change Advisory Board, record CAB-2026-058 |
| Approval date | 2026-08-06 |
| Last reviewed | 2026-09-01 |
| Owner | Priya Raman, Data Platform Engineering |
| Review cadence | Quarterly |

## 1. Scope

Applies to the instance **`(localdb)\MSSQLLocalDB`** on host `MAQN2000`, running **SQL Server 2025
Express Edition (64-bit)**, and the database `AdventureWorks2025`.

This is a self-managed instance. Patching is **our** responsibility — it is not a PaaS service and
Microsoft does not apply updates on our behalf.

## 2. Maintenance windows

| Environment | Window | Frequency | How it is announced |
| --- | --- | --- | --- |
| Analyst sandbox — `(localdb)\MSSQLLocalDB` | Wednesdays 18:00–20:00 local | Weekly, used as needed | Teams channel `#dw-platform`, 24 h ahead |
| Emergency (security-rated) | Any time | As required | Teams channel + direct message to the 3 named analysts |

Because the platform carries no SLA and has a single-digit user population, the window is short and
does not require formal downtime approval. Analysts are told to close Power BI sessions before
18:00 on Wednesdays.

## 3. Patching approach

| Aspect | Position |
| --- | --- |
| Who decides | Platform owner (P. Raman) reviews the monthly Microsoft release notes |
| What is applied | Cumulative Updates for SQL Server 2025; Windows updates on the host |
| Cadence | CUs applied within 30 days of release; security-rated updates within 7 days |
| Pre-production soak | Applied first to an engineer's local LocalDB instance and left for 3 working days before the shared sandbox |
| Approval | Standard changes pre-approved under CAB-2026-058; emergency changes notified retrospectively within 1 working day |
| Rollback | LocalDB instance is deleted and recreated from the schema in source control, then reloaded from the latest nightly export. Rollback is a rebuild, not an uninstall. |
| Verification | `SELECT @@VERSION` recorded before and after; a smoke query against `Sales.SalesOrderHeader` confirms the database is online |

## 4. Maintenance record

| Date | Action | Applied by | Outcome |
| --- | --- | --- | --- |
| 2026-09-09 | Host Windows cumulative update | P. Raman | Success; instance restarted cleanly |
| 2026-08-26 | SQL Server 2025 CU2 | P. Raman | Success; `@@VERSION` verified post-patch |
| 2026-08-12 | Host Windows cumulative update | A. Whitfield | Success |
| 2026-07-29 | SQL Server 2025 CU1 | P. Raman | Success; rolled forward from the 2022 engine |
| 2026-07-15 | Host Windows cumulative update | P. Raman | Success |

The record is maintained in this document at the time each change is applied. The most recent entry
is within the last 30 days, so the process is demonstrably live rather than aspirational.

## 5. Exclusions

Nothing in scope is vendor-managed. There is no Azure-managed patching to defer to.

## 6. Change history

| Version | Date | Change |
| --- | --- | --- |
| 3.4 | 2026-09-01 | Added September maintenance entry; reconfirmed windows |
| 3.3 | 2026-08-06 | Re-approved at CAB-2026-058 after the SQL Server 2025 upgrade |
| 3.0 | 2026-07-20 | Rewritten for the Express/LocalDB platform |
