# Deployment Model and Rationale — AdventureWorks Data Platform

| Field | Value |
| --- | --- |
| Document version | 3.1 |
| Status | **Approved** |
| Approved by | Architecture Review Board, record ARB-2026-014 |
| Approval date | 2026-07-30 |
| Last reviewed | 2026-08-28 |
| Owner | Priya Raman, Data Platform Engineering |
| Review cadence | Every 6 months, or on any change to the hosting model |

## 1. Chosen deployment model

The AdventureWorks data platform runs on **SQL Server (Express Edition) hosted as a LocalDB
instance**, `(localdb)\MSSQLLocalDB` on host `MAQN2000`. It is not Azure SQL Managed Instance and
not Azure SQL Database.

Product level in use: **SQL Server 2025, Express Edition (64-bit)**, EngineEdition 4.

## 2. Why this model was chosen

This is a **development and analyst sandbox**, not a production warehouse. The decision was taken
deliberately at ARB-2026-014, and the reasoning is recorded here so it is not re-litigated:

1. **Cost.** The workload is a single analyst-facing copy of `AdventureWorks2025` (71 user tables,
   under 1 GB). Express is licence-free and the data volume sits well inside the 10 GB cap.
2. **No availability requirement.** The platform carries no SLA. It is rebuildable from source
   control and a nightly export within 30 minutes, so redundancy was explicitly judged unnecessary.
   See [failover-behaviour.md](../operations/failover-behaviour.md) for the accepted position.
3. **Local development parity.** LocalDB lets each engineer run the same engine version on their own
   machine, which keeps schema development honest without provisioning shared infrastructure.
4. **Azure SQL rejected, with reasons.** Managed Instance was rejected on cost for a non-production
   workload. Azure SQL Database was rejected because the team needs instance-level features during
   development (cross-database queries against `msdb` for legacy SSIS package inspection).

## 3. Accepted consequences

These are known and accepted, not oversights:

- **No high availability.** Express supports no availability groups, no failover clustering and no
  readable replicas. The instance is single-node by design.
- **No SQL Server Agent.** Express omits Agent, so all scheduling is external (Windows Task
  Scheduler on the host). This is described in [etl-design.md](../etl/etl-design.md).
- **Not production-eligible.** If this platform is ever promoted to serve business reporting, this
  document must be reopened and the model re-decided; Express is not an acceptable production tier.

## 4. Scope of this document

Applies to the instance `(localdb)\MSSQLLocalDB` and the database `AdventureWorks2025` only.

## 5. Change history

| Version | Date | Change | Author |
| --- | --- | --- | --- |
| 3.1 | 2026-08-28 | Reconfirmed Express/LocalDB after the 2025 engine upgrade | P. Raman |
| 3.0 | 2026-07-30 | Rewritten for SQL Server 2025; ARB-2026-014 approval recorded | P. Raman |
| 2.4 | 2026-02-11 | Added the Azure SQL rejection rationale | M. Okafor |
