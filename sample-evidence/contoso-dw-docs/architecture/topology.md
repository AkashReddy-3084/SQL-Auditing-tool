# Server and Database Topology — Contoso Data Warehouse

**Version:** 2.4
**Last reviewed:** 2026-08-28
**Owner:** Data Platform Team

## 1. Instances

| Instance | Host | Edition / version | Environment | Purpose |
|----------|------|-------------------|-------------|---------|
| `VRSVPSQL1C` | vrsvpsql1c.contoso.local | SQL Server 2022 Enterprise 16.0.4150.1 | Production | Staging + warehouse |
| `VRSVTSQL1C` | vrsvtsql1c.contoso.local | SQL Server 2022 Developer 16.0.4150.1 | Test | Pre-production validation |
| `(localdb)\MSSQLLocalDB` | developer workstations | SQL Server 2022 Express LocalDB | Development | Local schema work |

There are no elastic pools — that is an Azure SQL Database construct and does not apply to this
on-premises deployment.

## 2. Databases

### Production — `VRSVPSQL1C`

| Database | Recovery model | Approx. size | Purpose |
|----------|----------------|--------------|---------|
| `ContosoStaging` | Simple | 180 GB | Raw landing zone, truncated and reloaded nightly |
| `ContosoDW` | Full | 640 GB | Conformed dimensional model consumed by reporting |
| `ContosoAudit` | Simple | 12 GB | ETL run log and data quality results |

### Test — `VRSVTSQL1C`

| Database | Recovery model | Approx. size | Purpose |
|----------|----------------|--------------|---------|
| `ContosoStaging` | Simple | 20 GB | Subset of production staging |
| `ContosoDW` | Simple | 55 GB | Subset of production warehouse |

## 3. Environment separation

Development, Test and Production are **separate physical instances**. They share no databases,
no logins and no storage. Promotion is Dev → Test → Prod and is described in the release
documentation held by the application team.

## 4. Dependencies

| Database | Depends on |
|----------|------------|
| `ContosoDW` | `ContosoStaging` (cross-database reads during the nightly transform) |
| `ContosoAudit` | None |

## 5. Change history

| Date | Change |
|------|--------|
| 2026-08-28 | Reviewed; `ContosoAudit` size updated |
| 2026-03-02 | `VRSVTSQL1C` upgraded to SQL Server 2022 |
| 2025-11-14 | `ContosoAudit` added |
