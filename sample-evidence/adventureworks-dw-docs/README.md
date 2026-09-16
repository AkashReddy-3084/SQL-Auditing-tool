# AdventureWorks Data Platform — Documentation Set

Documentation for the AdventureWorks analyst data platform, maintained by Data Platform Engineering.

## Platform in scope

| Property | Value |
| --- | --- |
| Instance | `(localdb)\MSSQLLocalDB` (host `MAQN2000`) |
| Product | SQL Server 2025, Express Edition (64-bit), EngineEdition 4 |
| User database | `AdventureWorks2025` (SIMPLE recovery, 71 user tables) |
| Schemas | `dbo`, `HumanResources`, `Person`, `Production`, `Purchasing`, `Sales` |
| High availability | None configured — single node, `IsHadrEnabled = 0`, `IsClustered = 0` |
| SQL Server Agent | Not available on Express; scheduling is external |

## Contents

### Architecture

- [deployment-model.md](architecture/deployment-model.md) — hosting model chosen, why, and the
  alternatives that were rejected.
- [server-database-topology.md](architecture/server-database-topology.md) — instance and database
  inventory, schema layout, dependencies.
- [architecture-diagram.md](architecture/architecture-diagram.md) — current-state diagram and the
  checks used to verify it against the live instance.

### Operations

- [failover-behaviour.md](operations/failover-behaviour.md) — availability position, manual recovery
  procedure, and the testing status of that procedure.
- [maintenance-and-patching.md](operations/maintenance-and-patching.md) — maintenance windows,
  patching process, approvals, rollback, and the record of recent maintenance.

### ETL

- [etl-design.md](etl/etl-design.md) — orchestration, data flow, transformations applied, and known
  design limitations.
- [source-to-target-mapping.md](etl/source-to-target-mapping.md) — column-level mappings for all six
  source feeds.
- `appsettings.sample.json` — sample load configuration. **Every credential in this file is fake.**

## Ownership

Data Platform Engineering — Priya Raman (priya.raman@example.invalid).
ETL documents are owned by Adaeze Whitfield (adaeze.whitfield@example.invalid).
Reviewed quarterly.
