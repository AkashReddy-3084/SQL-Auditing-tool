# Server and Database Topology — AdventureWorks Data Platform

| Field | Value |
| --- | --- |
| Document version | 2.6 |
| Status | **Approved** |
| Approved by | Data Platform Engineering, change record CHG-2026-0442 |
| Last reviewed | 2026-09-02 |
| Owner | Priya Raman, Data Platform Engineering |
| Review cadence | Quarterly, and on any instance or database addition |

## 1. Instance inventory

| Instance | Host | Product | Edition | Purpose |
| --- | --- | --- | --- | --- |
| `(localdb)\MSSQLLocalDB` | `MAQN2000` | SQL Server 2025 | Express (64-bit) | Analyst and development sandbox |

There is exactly **one** instance in scope. No named production instance, no failover cluster
instance and no Azure resource forms part of this platform.

## 2. Database inventory

| Database | Recovery model | User tables | Purpose |
| --- | --- | --- | --- |
| `AdventureWorks2025` | SIMPLE | 71 | Sample sales/production dataset used for reporting development |

System databases (`master`, `model`, `msdb`, `tempdb`) are present as supplied by the engine. `msdb`
retains 8 legacy SSIS packages inherited from the previous platform; these are dormant and are
tracked for removal under CHG-2026-0451.

SIMPLE recovery is deliberate: the database is rebuildable from source control and the nightly
export, so point-in-time recovery is not required and log management overhead is avoided.

## 3. Elastic pools

**None.** Elastic pools are an Azure SQL Database construct and do not apply to this deployment.
Recorded here explicitly so the absence is understood as a decision rather than an omission.

## 4. Schema layout

`AdventureWorks2025` organises objects across six schemas:

| Schema | Objects | Responsibility |
| --- | --- | --- |
| `dbo` | 21 | Utility objects, error logging (`dbo.ErrorLog`) |
| `HumanResources` | 15 | Employee, department and pay history |
| `Person` | 15 | Party, contact and address data |
| `Production` | 28 | Product, bill of materials, work orders |
| `Purchasing` | 7 | Vendors and purchase orders |
| `Sales` | 26 | Customers, orders, territories, currency |

## 5. Dependencies

| Dependency | Direction | Notes |
| --- | --- | --- |
| Host filesystem `D:\dw-extracts` | Outbound | Nightly CSV export target |
| Windows Task Scheduler (`MAQN2000`) | Inbound | Triggers the load; Agent is unavailable on Express |
| Power BI Desktop (analyst workstations) | Inbound | Direct import connections |

No linked servers, no replication publications and no service broker endpoints are configured.

## 6. Change history

| Version | Date | Change |
| --- | --- | --- |
| 2.6 | 2026-09-02 | Added schema object counts after the 2025 refresh |
| 2.5 | 2026-06-18 | Recorded the dormant msdb SSIS packages |
| 2.4 | 2026-03-05 | Documented the elastic-pool non-applicability |
