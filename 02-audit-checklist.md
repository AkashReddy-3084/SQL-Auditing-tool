# Audit Checklist — MLC SQL (SQL Server / Azure SQL Data Warehouse) Solution

> **Instructions**: Score each item 0–3 per the [Scoring Rubric](01-scoring-rubric.md). Mark N/A with written justification. Record evidence/observations in the Notes column.
>
> **Legend**: Score 0 = Not Implemented | 1 = Partial | 2 = Implemented | 3 = Best Practice | N/A = Not Applicable
>
> **Solution profile**: MLC SQL Server data platform. Confirmed environment (SQL walkthrough): **on-premises SQL Server in High Availability**, hosting in-house applications — **Production** two-node HA (`C1SVPMLSQL01` / `C1SVPMLSQL02`) reached via the alias `C1SVPMLSQLAPP01`; a corresponding **Test** two-node HA (`…T01` / `…T02`). Applications connect through the alias, never the individual nodes; failover between nodes is intended to be transparent. Naming encodes environment (**P** = Production, **T** = Test). A complete server/application inventory is **pending** from the client. This kit covers architecture/HA, database & (where applicable) dimensional design, T-SQL code, security, reliability, monitoring, performance tuning, DevOps, cost, documentation, and governance.
>
> **Deployment note**: Confirmed mode is **on-premises SQL Server (IaaS-style)** — Azure SQL Database / Managed Instance PaaS-only items are **N/A** (mark with justification). The OS/host layer, Windows Failover Cluster (WSFC), and Always On AG / FCI **are** in scope. Azure **Reader**, **Azure DevOps** (repos + pipelines), and (if deployed) **Purview** / **Defender** access are still needed for surrounding infrastructure, source control, and security/governance posture.
>
> **Workload-type note**: Where a database is a **transactional / OLTP application database** (as indicated for the in-house apps) rather than a data warehouse, the DW-specific areas — **Area 2 (Data Integration & ETL)** and **Area 4.2 (Dimensional Modeling)** — are largely **N/A**; score them per database and justify N/A. OLTP concerns (concurrency, blocking/deadlocks, index maintenance, connection resilience) are covered in Areas 3, 9, and 14. **Run this checklist per instance / HA cluster**, inspecting each physical node.

---

## Audit Category Legend

> Every checklist item is assigned a **Category (Cat)** value indicating how the item will be assessed during the audit:
>
> | Cat | Label | Description |
> |-----|-------|-------------|
> | **1** | **Automated** | Can be assessed via script, AI, or Playwright-based automation. The auditor (with `VIEW SERVER STATE` / `VIEW ANY DEFINITION` / `db_datareader` access) can run T-SQL queries against DMVs, scan source code in the repo, inspect SQL Agent jobs, or query system catalogs to verify this item programmatically. |
> | **2** | **Admin Review** | Requires admin-level access the auditor does not have (sysadmin, OS-level, WSFC, Azure Portal, Entra ID, Key Vault, etc.). The auditor will request the client's DBA/admin team to navigate to the relevant admin panel, run the privileged query, or provide a screenshot. The auditor fills in the score based on what is shown. |
> | **3** | **Client Documentation** | Requires documentation, policies, processes, or domain knowledge that resides with the client's development/operations team. The auditor will share these items with the client team; they will provide the evidence and fill in the details, then submit the checklist section for auditor review. |

---

## Area 1: Architecture & Design (Weight: 8%)

### 1.1 Solution & Deployment Architecture

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 1.1.1 | Deployment model is deliberate and documented (SQL Server / Azure SQL MI / Azure SQL DB) with rationale | 3 | | |
| 1.1.2 | Environment separation exists (Dev / Test / Prod) with isolated instances or databases | 1 | | |
| 1.1.3 | Server/database topology documented (instances, databases, elastic pools) | 3 | | |
| 1.1.4 | Compute tier / service tier appropriate for workload (vCore/DTU, Business Critical/General Purpose) | 1 | | |
| 1.1.5 | Architecture diagram exists and reflects the actual implementation | 3 | | |
| 1.1.6 | Single source of truth — no duplicate warehouses serving the same purpose | 1 | | |
| 1.1.7 | Capacity/scale approach documented (scale-up vs scale-out, read replicas) | 3 | | |

### 1.2 Data Architecture (Staging / ODS / DW / Marts)

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 1.2.1 | Clear layering defined (staging → ODS/integration → dimensional DW → data marts) | 1 | | |
| 1.2.2 | Each layer has a defined purpose and transformation responsibility | 3 | | |
| 1.2.3 | Staging area is transient/isolated and not queried by consumers | 1 | | |
| 1.2.4 | Data flow lineage is traceable end-to-end from source to mart | 3 | | |
| 1.2.5 | Schema separation used to organize layers/domains (dedicated schemas, not all in dbo) | 1 | | |
| 1.2.6 | Audit metadata captured on load (load_date, source_system, batch_id) | 1 | | |
| 1.2.7 | Historical/archival strategy defined for the DW | 3 | | |

### 1.3 High Availability Topology

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 1.3.1 | HA approach defined and matches SLA (Always On AG / failover cluster / zone-redundant / failover groups) | 1 | | |
| 1.3.2 | Redundancy configured for the production database (replicas / zone redundancy) | 1 | | |
| 1.3.3 | Read-scale replicas used for reporting where appropriate | 1 | | |
| 1.3.4 | Failover behavior documented and tested | 3 | | |
| 1.3.5 | Connection strings use listener / failover-group endpoints (not a single node) | 1 | | |
| 1.3.6 | Maintenance windows and patching approach defined (or Microsoft-managed for PaaS) | 3 | | |
| 1.3.7 | Application connection endpoint is a failover-aware **AG Listener** / FCI virtual network name — not a static client alias or DNS CNAME that must be manually repointed on failover (verify what the alias `C1SVPMLSQLAPP01` actually resolves to) | 1 | | |
| 1.3.8 | Multi-subnet AG connections use `MultiSubnetFailover=True` with an appropriate connect timeout in application connection strings | 2 | | |
| 1.3.9 | Alias / DNS resolution and failover behavior documented and validated — applications reconnect transparently on failover with no manual repoint | 3 | | |
| 1.3.10 | HA node configuration parity verified — both nodes have identical instance configuration, trace flags, MAXDOP/memory, logins, SQL Agent jobs, linked servers, and certificates | 1 | | |

---

## Area 2: Data Integration & ETL (Weight: 10%)

### 2.1 ETL/ELT Design

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 2.1.1 | ETL tooling is consistent and deliberate (SSIS / Azure Data Factory / T-SQL / other) | 1 | | |
| 2.1.2 | ETL packages/pipelines follow consistent naming conventions | 1 | | |
| 2.1.3 | ETL is parameterized (no hardcoded servers, paths, dates, or credentials) | 1 | | |
| 2.1.4 | Orchestration/dependency management exists (master package/pipeline or scheduler) | 1 | | |
| 2.1.5 | Reusable/templated ETL components (no copy-paste per table) | 1 | | |
| 2.1.6 | ETL is metadata-driven or well-modularized where appropriate | 1 | | |
| 2.1.7 | ETL is logically documented (data flow, transformations, source-to-target mappings) | 3 | | |

### 2.2 Incremental Load & Change Data Capture

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 2.2.1 | Incremental load implemented where applicable (watermark / CDC / Change Tracking) | 1 | | |
| 2.2.2 | Full load reserved for small reference/dimension tables or initial loads | 1 | | |
| 2.2.3 | Watermark/control values persisted reliably (control table, not volatile) | 1 | | |
| 2.2.4 | CDC / Change Tracking configured and maintained correctly where used | 1 | | |
| 2.2.5 | Insert/Update/Delete operations handled correctly (MERGE or equivalent) | 1 | | |
| 2.2.6 | Late-arriving / out-of-order data handled without corruption | 1 | | |

### 2.3 Error Handling & Restartability

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 2.3.1 | ETL has structured error handling (TRY...CATCH, event handlers, failure paths) | 1 | | |
| 2.3.2 | Failed loads are restartable from point of failure (not full re-run) | 1 | | |
| 2.3.3 | Bad/rejected rows routed to a quarantine/error table (not silently dropped or failing the batch) | 1 | | |
| 2.3.4 | Retry logic exists for transient failures | 1 | | |
| 2.3.5 | ETL runs are idempotent (re-run does not duplicate data) | 1 | | |
| 2.3.6 | Failures trigger notifications (email/alert/monitoring) | 1 | | |

### 2.4 ETL Performance

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 2.4.1 | Bulk load patterns used (BULK INSERT / bcp / minimal logging) for large loads | 1 | | |
| 2.4.2 | Set-based operations preferred over row-by-row processing | 1 | | |
| 2.4.3 | Indexes/constraints managed during large loads (disable/rebuild where beneficial) | 1 | | |
| 2.4.4 | ETL windows avoid contention with reporting/query workloads | 1 | | |
| 2.4.5 | ETL execution times monitored and baselined | 1 | | |
| 2.4.6 | Parallelism used appropriately (no unnecessary serial execution) | 1 | | |

---

## Area 3: T-SQL Code Quality (Weight: 8%)

### 3.1 Coding Standards

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 3.1.1 | Consistent formatting and naming conventions across objects | 1 | | |
| 3.1.2 | No `SELECT *` in production code; explicit column lists | 1 | | |
| 3.1.3 | Schema-qualified object references (dbo.Table, not Table) | 1 | | |
| 3.1.4 | `SET NOCOUNT ON` and appropriate SET options in procedures | 1 | | |
| 3.1.5 | No deprecated syntax/features (e.g., old-style joins, `TEXT`/`NTEXT`) | 1 | | |
| 3.1.6 | Code is commented for complex logic; business rules explained | 1 | | |
| 3.1.7 | No hardcoded literals for environment-specific values | 1 | | |

### 3.2 Stored Procedures & Programmability

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 3.2.1 | Business/transformation logic encapsulated in stored procedures/functions (not ad-hoc scripts) | 1 | | |
| 3.2.2 | Set-based logic used; cursors/`WHILE` loops avoided except where justified | 1 | | |
| 3.2.3 | Scalar UDFs avoided in hot paths (inlined/replaced where they hurt performance) | 1 | | |
| 3.2.4 | Views used appropriately (no deeply nested view chains that hide cost) | 1 | | |
| 3.2.5 | Dynamic SQL, where used, is parameterized (sp_executesql) — no injection risk | 1 | | |
| 3.2.6 | Temp tables vs table variables chosen appropriately for cardinality | 1 | | |

### 3.3 Transactions & Error Handling

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 3.3.1 | Transactions scoped correctly (not held open across long operations) | 1 | | |
| 3.3.2 | `TRY...CATCH` with proper error raising/logging (THROW/RAISERROR) | 1 | | |
| 3.3.3 | `XACT_ABORT` / transaction state handling correct on error | 1 | | |
| 3.3.4 | Appropriate isolation levels used (no unnecessary SERIALIZABLE; RCSI considered) | 1 | | |
| 3.3.5 | Deadlock-prone patterns avoided; retry logic where needed | 1 | | |
| 3.3.6 | Multi-step operations maintain consistency on partial failure | 1 | | |

---

## Area 4: Data Modeling & Storage (Weight: 9%)

### 4.1 Schema & Normalization

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 4.1.1 | Modeling approach is deliberate (3NF integration layer and/or dimensional marts) | 1 | | |
| 4.1.2 | Naming conventions consistent for tables, columns, and schemas | 1 | | |
| 4.1.3 | Data types appropriate and right-sized (no oversized varchar, correct numeric precision) | 1 | | |
| 4.1.4 | No stringly-typed dates/numbers; correct temporal types | 1 | | |
| 4.1.5 | Audit columns present where needed (created/modified, source, batch) | 1 | | |
| 4.1.6 | Schemas used to organize objects by layer/domain | 1 | | |

### 4.2 Dimensional Modeling

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 4.2.1 | Star schema implemented (fact + dimension tables, not flat wide tables) | 1 | | |
| 4.2.2 | Fact table grain clearly defined and documented per fact | 1 | | |
| 4.2.3 | Fact tables contain only foreign keys and measures (no descriptive attributes) | 1 | | |
| 4.2.4 | Surrogate keys used for dimensions (IDENTITY/sequence), not business keys in facts | 1 | | |
| 4.2.5 | Conformed dimensions shared across facts (no duplicate versions) | 1 | | |
| 4.2.6 | Date/Time dimension exists with required attributes | 1 | | |
| 4.2.7 | SCD strategy defined and implemented per dimension (Type 1/2/3) | 1 | | |
| 4.2.8 | SCD Type 2 valid_from/valid_to/is_current maintained correctly (where used) | 1 | | |

### 4.3 Indexing Strategy

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 4.3.1 | Every table has an appropriate clustered index (or deliberate heap justification) | 1 | | |
| 4.3.2 | Columnstore indexes used for large fact tables / analytical workloads where appropriate | 1 | | |
| 4.3.3 | Nonclustered indexes align with query/workload patterns (not arbitrary) | 1 | | |
| 4.3.4 | No redundant/duplicate/overlapping indexes | 1 | | |
| 4.3.5 | Unused indexes identified and removed (DMV evidence) | 1 | | |
| 4.3.6 | Missing-index recommendations reviewed (not blindly applied) | 1 | | |
| 4.3.7 | Fill factor and index options set deliberately where needed | 1 | | |
| 4.3.8 | Index maintenance (rebuild/reorganize) scheduled based on fragmentation | 1 | | |

### 4.4 Partitioning & Storage

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 4.4.1 | Partitioning strategy defined for large tables (by date/range) where beneficial | 1 | | |
| 4.4.2 | Partition alignment supports fast load/switch and purge (sliding window) | 1 | | |
| 4.4.3 | Filegroups used to organize storage where applicable (SQL Server/MI) | 1 | | |
| 4.4.4 | Data compression (row/page/columnstore) applied where beneficial | 1 | | |
| 4.4.5 | tempdb configured appropriately (multiple files, sizing) — SQL Server/MI | 1 | | |
| 4.4.6 | Storage growth monitored; autogrowth settings sane (fixed size, not tiny %) | 1 | | |
| 4.4.7 | Archival/purge process exists for aged data | 3 | | |

### 4.5 Keys & Constraints

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 4.5.1 | Primary keys defined on all tables | 1 | | |
| 4.5.2 | Foreign keys enforced where integrity matters (or documented trusted-by-ETL exceptions) | 1 | | |
| 4.5.3 | Unique constraints on natural/business keys where appropriate | 1 | | |
| 4.5.4 | Check constraints enforce domain rules where practical | 1 | | |
| 4.5.5 | Constraints are TRUSTED (not disabled/untrusted, which hurts the optimizer) | 1 | | |
| 4.5.6 | NOT NULL applied to mandatory columns | 1 | | |

---

## Area 5: Data Quality Framework (Weight: 9%)

### 5.1 DQ Framework & Governance

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 5.1.1 | Data quality framework formally defined with rules, ownership, and scoring | 3 | | |
| 5.1.2 | DQ rules codified (config-driven or reusable procedures), not ad-hoc manual checks | 1 | | |
| 5.1.3 | DQ KPIs defined: completeness, accuracy, timeliness, consistency, uniqueness, validity | 3 | | |
| 5.1.4 | DQ results logged and trended over time | 1 | | |
| 5.1.5 | DQ remediation workflow exists (alert → investigate → fix → verify) | 3 | | |
| 5.1.6 | DQ SLAs defined per data product / mart | 3 | | |
| 5.1.7 | DQ failures halt progression where critical (bad data not silently promoted) | 1 | | |
| 5.1.8 | Quarantine pattern: failed rows routed to error tables with failure reason | 1 | | |

### 5.2 Source / Staging Validation

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 5.2.1 | Schema validation on inbound data (column presence, types) | 1 | | |
| 5.2.2 | Completeness: all expected sources/batches received | 1 | | |
| 5.2.3 | Record count reconciliation vs. source control counts | 1 | | |
| 5.2.4 | Duplicate detection across batches | 1 | | |
| 5.2.5 | Null/empty handling: unexpected nulls flagged | 1 | | |
| 5.2.6 | Corrupt/malformed rows isolated (not failing the entire batch) | 1 | | |
| 5.2.7 | Source metadata captured (load timestamp, source, batch ID) | 1 | | |

### 5.3 DW / Mart Validation

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 5.3.1 | Referential integrity validated (FKs in facts match dimensions) | 1 | | |
| 5.3.2 | Business rule validation applied (domain rules, ranges) | 1 | | |
| 5.3.3 | Deduplication verified — no duplicate business keys after load | 1 | | |
| 5.3.4 | Aggregate consistency: detail sums equal aggregate totals | 1 | | |
| 5.3.5 | Cross-layer reconciliation (mart vs integration vs source counts) | 1 | | |
| 5.3.6 | Unknown/default dimension member usage monitored | 1 | | |
| 5.3.7 | No duplicate grain in fact tables | 1 | | |
| 5.3.8 | Freshness validation: marts updated within SLA | 1 | | |

### 5.4 Data-Type-Specific Validation Rules

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 5.4.1 | **Dates**: valid ranges; consistent handling; no invalid future dates where prohibited | 1 | | |
| 5.4.2 | **Numeric / Financial**: precision preserved; no rounding errors; currency codes valid | 1 | | |
| 5.4.3 | **String / Text**: encoding/collation consistent; max length respected; no silent truncation | 1 | | |
| 5.4.4 | **Sensitive data**: masked/protected where required; format validation applied | 1 | | |
| 5.4.5 | **Categorical / Enum**: values within expected domain; no invalid codes | 1 | | |
| 5.4.6 | **Identifiers / Keys**: uniqueness verified; format consistent; no nulls in keys | 1 | | |
| 5.4.7 | **Boolean / Flag**: only expected values; consistent representation across tables | 1 | | |

---

## Area 6: Security & Access Control (Weight: 12%)

### 6.1 Authentication & Authorization

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 6.1.1 | Microsoft Entra ID (Azure AD) authentication used where possible (over SQL auth) | 1 | | |
| 6.1.2 | Principle of least privilege applied to logins/users (no broad db_owner/sysadmin) | 1 | | |
| 6.1.3 | Database roles used for permission grants (not per-user grants) | 1 | | |
| 6.1.4 | Application connects via a dedicated least-privilege service account/identity (Managed Identity preferred) | 1 | | |
| 6.1.5 | No shared/generic accounts for administrative or application access | 1 | | |
| 6.1.6 | Guest/contractor access explicitly governed and time-bound | 2 | | |
| 6.1.7 | Regular access reviews scheduled and documented | 3 | | |
| 6.1.8 | Schema/object-level permissions align with least privilege | 1 | | |

### 6.2 Data Protection

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 6.2.1 | Transparent Data Encryption (TDE) enabled for encryption at rest | 1 | | |
| 6.2.2 | TLS enforced for data in transit (Encrypt=true; minimum TLS version set) | 2 | | |
| 6.2.3 | Always Encrypted used for highly sensitive columns where required | 1 | | |
| 6.2.4 | Dynamic Data Masking applied to sensitive columns where appropriate | 1 | | |
| 6.2.5 | Row-Level Security implemented where multi-tenant/segmented access is required | 1 | | |
| 6.2.6 | Sensitive data classified (SQL Data Discovery & Classification / labels) | 1 | | |
| 6.2.7 | Backups are encrypted | 2 | | |
| 6.2.8 | Customer-managed keys (CMK/BYOK) used where policy requires | 2 | | |

### 6.3 Network Security

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 6.3.1 | Firewall / network rules restrict access to known sources | 2 | | |
| 6.3.2 | Private endpoints / VNet integration used (Azure SQL) or network isolation (SQL Server) | 2 | | |
| 6.3.3 | Public network access disabled or tightly restricted (Azure SQL) | 2 | | |
| 6.3.4 | No broad "allow Azure services" / 0.0.0.0 firewall rules | 2 | | |
| 6.3.5 | Jump-host/bastion or controlled path for administrative access | 2 | | |

### 6.4 Secrets & Key Management

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 6.4.1 | Connection strings/secrets stored in a secret store (Key Vault), not config files or code | 2 | | |
| 6.4.2 | No credentials hardcoded in ETL packages, scripts, or linked servers | 1 | | |
| 6.4.3 | Managed Identity used for service-to-service auth where supported | 2 | | |
| 6.4.4 | Credential/key rotation policy defined and automated | 2 | | |
| 6.4.5 | Linked servers / external data sources use least-privilege, non-personal credentials | 1 | | |

---

## Area 7: Compliance & Regulatory (Weight: 7%)

> **Note**: MLC's regulatory regime is **TBD**. This area captures generic controls plus a plug-in slot for the confirmed regime(s). Detailed mappings are in [03-compliance-matrix.md](03-compliance-matrix.md).

### 7.1 Regulatory Regime (Plug-in — TBD)

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 7.1.1 | Applicable regulatory/compliance regime(s) identified and documented | 3 | | |
| 7.1.2 | In-scope regulated data categories identified and inventoried | 3 | | |
| 7.1.3 | Regime-specific control set mapped into the compliance matrix | 3 | | |
| 7.1.4 | Data residency / regional processing requirements identified and met | 3 | | |
| 7.1.5 | Required agreements in place (e.g., DPA) covering the platform and services | 3 | | |
| 7.1.6 | Breach / incident notification process documented | 3 | | |

### 7.2 Financial Data Controls (SOX-style ITGC)

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 7.2.1 | Segregation of Duties enforced (developer ≠ deployer ≠ approver) | 2 | | |
| 7.2.2 | All schema/code changes go through formal change management | 3 | | |
| 7.2.3 | Audit trail for changes to financial-relevant data | 1 | | |
| 7.2.4 | Access control changes logged and reviewable | 1 | | |
| 7.2.5 | Transformation logic documented and reproducible | 3 | | |
| 7.2.6 | Source-to-target reconciliation exists for financial data | 1 | | |
| 7.2.7 | Retention of historical financial data per policy | 3 | | |

### 7.3 Data Privacy (Generic Placeholder)

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 7.3.1 | Personal data inventory exists with legal basis (if personal data is processed) | 3 | | |
| 7.3.2 | Data minimization applied — only necessary personal data stored | 3 | | |
| 7.3.3 | Right-to-erasure / rectification technically achievable | 3 | | |
| 7.3.4 | Data retention policies defined per data category | 3 | | |
| 7.3.5 | Consent / purpose tracking integrated where applicable | 3 | | |
| 7.3.6 | Cross-border transfer justified and documented (if applicable) | 3 | | |

### 7.4 Audit Trail & Logging

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 7.4.1 | SQL Audit (server/database) enabled for sensitive operations | 1 | | |
| 7.4.2 | Login/permission changes captured and reviewable | 1 | | |
| 7.4.3 | Data access to sensitive tables auditable (who accessed what, when) | 1 | | |
| 7.4.4 | Audit logs retained per compliance requirement | 2 | | |
| 7.4.5 | Audit logs stored in a tamper-resistant location (separate store / immutable) | 2 | | |
| 7.4.6 | Temporal tables / change tracking used for data history where required | 1 | | |

---

## Area 8: Data Governance (Weight: 4%)

### 8.1 Lineage & Cataloging

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 8.1.1 | Source-to-target lineage documented (ETL mappings) | 3 | | |
| 8.1.2 | Enterprise catalog (e.g., Microsoft Purview) integrated or planned | 2 | | |
| 8.1.3 | Objects tagged/classified with business domain and owner | 1 | | |
| 8.1.4 | Dependencies documented (linked servers, cross-database references) | 1 | | |
| 8.1.5 | Extended properties / documentation on key objects | 1 | | |

### 8.2 Ownership & Stewardship

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 8.2.1 | Every table/dataset has a defined data owner | 3 | | |
| 8.2.2 | Data stewards assigned per domain/subject area | 3 | | |
| 8.2.3 | Ownership documented — not tribal knowledge | 3 | | |
| 8.2.4 | Escalation path for data quality issues defined | 3 | | |
| 8.2.5 | DBA/ops ownership and responsibilities defined | 3 | | |

### 8.3 Metadata & Data Dictionary

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 8.3.1 | Data dictionary exists for DW/mart tables | 3 | | |
| 8.3.2 | Technical metadata (schema) captured and current | 1 | | |
| 8.3.3 | Business definitions/rules documented and current | 3 | | |
| 8.3.4 | Metadata accessible to consumers (discoverable) | 3 | | |
| 8.3.5 | Business glossary / terminology maintained | 3 | | |

---

## Area 9: Reliability & Resilience (Weight: 6%)

### 9.1 Backup & Recovery

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 9.1.1 | Backup strategy defined and matches RPO (full/differential/log or PaaS automated) | 1 | | |
| 9.1.2 | Point-in-time restore capability verified (retention period appropriate) | 1 | | |
| 9.1.3 | Backups restore-tested regularly (not just taken) | 3 | | |
| 9.1.4 | Long-term retention (LTR) configured where required | 2 | | |
| 9.1.5 | Backups stored redundantly / geo-redundant where required | 2 | | |
| 9.1.6 | Backup failures alerted and monitored | 1 | | |
| 9.1.7 | Recovery model appropriate (Full/Simple/Bulk-logged) — SQL Server/MI | 1 | | |

### 9.2 High Availability & Disaster Recovery

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 9.2.1 | RTO and RPO defined and documented | 3 | | |
| 9.2.2 | HA solution matches SLA (Always On AG / failover groups / zone redundancy) | 1 | | |
| 9.2.3 | Geo-replication / failover group configured for DR where required | 1 | | |
| 9.2.4 | DR runbook documented | 3 | | |
| 9.2.5 | Failover tested at least annually | 3 | | |
| 9.2.6 | Secondary region/replica capacity provisioned or evaluated | 1 | | |
| 9.2.7 | Application connection resilience verified (retry logic, failover endpoints) | 2 | | |
| 9.2.8 | Availability mode (synchronous vs asynchronous commit) and failover mode (automatic vs manual) documented and aligned to RPO/RTO | 1 | | |
| 9.2.9 | AG / cluster health and replica synchronization state actively monitored — unhealthy or not-synchronizing replicas alerted | 1 | | |
| 9.2.10 | WSFC quorum / witness configured correctly for the node count (avoids split-brain); quorum model documented | 2 | | |
| 9.2.11 | Backup preference configured (backups taken from the preferred / secondary replica where used) and validated across failover | 1 | | |
| 9.2.12 | Listener / alias failover tested end-to-end — applications reconnect transparently with no manual intervention | 3 | | |

### 9.3 Data Integrity

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 9.3.1 | Consistency checks (DBCC CHECKDB) scheduled and monitored (SQL Server/MI) | 1 | | |
| 9.3.2 | Page verification set to CHECKSUM | 1 | | |
| 9.3.3 | Corruption detection alerting in place | 1 | | |
| 9.3.4 | ETL is idempotent — safe to re-run after failure | 1 | | |
| 9.3.5 | Multi-step operations maintain integrity on partial failure | 1 | | |

### 9.4 SLA Management

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 9.4.1 | Data freshness SLAs defined per mart/data product | 3 | | |
| 9.4.2 | Load completion SLAs set and monitored | 1 | | |
| 9.4.3 | SLA breach triggers alerts | 1 | | |
| 9.4.4 | Historical SLA compliance tracked and reported | 1 | | |

---

## Area 10: Monitoring & Observability (Weight: 5%)

### 10.1 Health & Performance Monitoring

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 10.1.1 | Monitoring solution in place (Azure Monitor / SQL Insights / third-party) | 2 | | |
| 10.1.2 | Key metrics tracked (CPU, memory, IO, DTU/vCore, waits) | 1 | | |
| 10.1.3 | Resource utilization trended over time | 1 | | |
| 10.1.4 | Alerts configured for resource saturation and errors | 1 | | |
| 10.1.5 | Long-running/blocking query alerting configured | 1 | | |
| 10.1.6 | Dashboard accessible to operations (not just DBAs) | 2 | | |

### 10.2 Query Store & DMVs

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 10.2.1 | Query Store enabled and configured appropriately | 1 | | |
| 10.2.2 | Query Store used to detect regressions and force plans where needed | 1 | | |
| 10.2.3 | DMVs used for ongoing performance analysis (waits, missing/unused indexes) | 1 | | |
| 10.2.4 | Wait statistics reviewed as part of routine tuning | 1 | | |
| 10.2.5 | Baselines captured for comparison over time | 3 | | |

### 10.3 Extended Events & Alerting

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 10.3.1 | Extended Events sessions used for diagnostics (over deprecated Profiler traces) | 1 | | |
| 10.3.2 | Deadlock capture configured | 1 | | |
| 10.3.3 | Error/severity alerts configured (Agent alerts or equivalent) | 1 | | |
| 10.3.4 | Alert thresholds tuned to avoid fatigue | 1 | | |
| 10.3.5 | Escalation path defined for critical alerts | 3 | | |

### 10.4 Job & ETL Monitoring

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 10.4.1 | ETL/job run history captured and retained | 1 | | |
| 10.4.2 | Job failures alert the responsible team | 1 | | |
| 10.4.3 | Job duration trends monitored | 1 | | |
| 10.4.4 | SQL Agent / scheduler jobs inventoried and owned | 1 | | |
| 10.4.5 | Log/rowcount reconciliation captured per ETL run | 1 | | |

---

## Area 11: DevOps & Deployment (Weight: 6%)

### 11.1 Version Control

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 11.1.1 | Database schema and code source-controlled (SSDT/SQL project or migration scripts) | 1 | | |
| 11.1.2 | ETL packages/pipelines source-controlled | 1 | | |
| 11.1.3 | Branching strategy defined (feature/main/release) | 1 | | |
| 11.1.4 | Pull request reviews required before merge | 1 | | |
| 11.1.5 | Commit messages descriptive and linked to work items | 1 | | |
| 11.1.6 | Secret-scanning enabled on the repository | 1 | | |

### 11.2 CI/CD & Database Deployment

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 11.2.1 | Automated build of the database project (DACPAC or migrations) | 1 | | |
| 11.2.2 | Automated deployment pipeline (Dev → Test → Prod) | 1 | | |
| 11.2.3 | Schema drift detected and reconciled between environments | 1 | | |
| 11.2.4 | No manual production changes — all via pipeline | 2 | | |
| 11.2.5 | Deployment approvals required (segregation of duties) | 2 | | |
| 11.2.6 | Rollback / recovery procedure defined and tested | 3 | | |
| 11.2.7 | Pre/post-deployment scripts managed and idempotent | 1 | | |

### 11.3 Environment Management

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 11.3.1 | Separate Dev / Test / Prod environments | 1 | | |
| 11.3.2 | Production access restricted (no developer write/deploy) | 2 | | |
| 11.3.3 | Test environment representative of production (data, scale) | 3 | | |
| 11.3.4 | Environment configuration parity maintained | 1 | | |
| 11.3.5 | Non-prod data masking/subsetting applied where sensitive | 2 | | |

### 11.4 Testing

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 11.4.1 | Unit tests exist for critical transformation logic (e.g., tSQLt) | 1 | | |
| 11.4.2 | Integration tests validate end-to-end ETL | 1 | | |
| 11.4.3 | Data validation tests run post-deployment (counts, schema checks) | 1 | | |
| 11.4.4 | Performance tests exist for critical queries/loads | 3 | | |
| 11.4.5 | Regression testing on schema changes | 3 | | |

---

## Area 12: Cost Management & Capacity (Weight: 4%)

### 12.1 Capacity Planning & Sizing

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 12.1.1 | Service tier / compute sizing based on workload analysis (not guesswork) | 3 | | |
| 12.1.2 | DTU/vCore utilization profiled (peak vs off-peak) | 1 | | |
| 12.1.3 | Elastic pools used where multiple databases share capacity efficiently | 1 | | |
| 12.1.4 | Auto-scaling / serverless considered where workload is intermittent | 2 | | |
| 12.1.5 | Growth projections modeled for next 6–12 months | 3 | | |
| 12.1.6 | Storage sizing and growth monitored | 1 | | |

### 12.2 Cost Optimization

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 12.2.1 | Reserved capacity / savings plans evaluated vs pay-as-you-go | 3 | | |
| 12.2.2 | Right-sizing reviewed periodically (over-provisioned tiers reduced) | 1 | | |
| 12.2.3 | Non-prod environments scaled down / paused when idle | 2 | | |
| 12.2.4 | Backup storage costs monitored (retention tuned) | 2 | | |
| 12.2.5 | Unused databases/objects/indexes cleaned up | 1 | | |
| 12.2.6 | Compression used to reduce storage and IO cost where beneficial | 1 | | |

---

## Area 13: Documentation & Knowledge Management (Weight: 3%)

### 13.1 Solution Documentation

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 13.1.1 | Architecture overview document exists | 3 | | |
| 13.1.2 | Data flow / source-to-target mappings documented | 3 | | |
| 13.1.3 | Business rules for transformations documented outside code | 3 | | |
| 13.1.4 | Known issues and tech debt registered | 3 | | |

### 13.2 Operational Runbooks

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 13.2.1 | Runbook exists for daily/weekly/monthly operations | 3 | | |
| 13.2.2 | Failure recovery procedures documented step-by-step | 3 | | |
| 13.2.3 | On-call / escalation procedures documented | 3 | | |
| 13.2.4 | Maintenance procedures documented (index/stats/integrity) | 3 | | |

### 13.3 Data Dictionary

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 13.3.1 | Table/column definitions documented with business context | 3 | | |
| 13.3.2 | Source-to-target mapping documented per table | 3 | | |
| 13.3.3 | Acronyms and business terminology glossary available | 3 | | |
| 13.3.4 | Documentation kept current with schema changes | 3 | | |

### 13.4 Knowledge Transfer

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 13.4.1 | Solution maintainable by someone other than the original builder | 3 | | |
| 13.4.2 | No single point of human dependency (bus factor > 1) | 3 | | |
| 13.4.3 | Onboarding materials exist for new team members | 3 | | |
| 13.4.4 | Code is self-documenting or well-commented for complex logic | 3 | | |

---

## Area 14: Performance & Query Tuning (Weight: 9%)

### 14.1 Execution Plans & Query Design

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 14.1.1 | Critical queries reviewed via execution plans (no unexpected scans/spools) | 1 | | |
| 14.1.2 | SARGable predicates used (no functions wrapping indexed columns) | 1 | | |
| 14.1.3 | Set-based rewrites applied where cursors/loops caused poor plans | 1 | | |
| 14.1.4 | Implicit conversions eliminated (data-type mismatches in joins/filters) | 1 | | |
| 14.1.5 | Excessive/unnecessary sorts and spools addressed | 1 | | |
| 14.1.6 | Key lookups minimized via covering indexes where beneficial | 1 | | |
| 14.1.7 | Query hints used sparingly and documented where present | 1 | | |

### 14.2 Index Tuning & Maintenance

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 14.2.1 | Index usage analyzed (seeks vs scans) against workload | 1 | | |
| 14.2.2 | Missing indexes reviewed and applied judiciously | 1 | | |
| 14.2.3 | Unused/duplicate indexes removed | 1 | | |
| 14.2.4 | Fragmentation-based maintenance (rebuild/reorganize) automated | 1 | | |
| 14.2.5 | Columnstore health maintained (rowgroup quality, tuple mover) where used | 1 | | |
| 14.2.6 | Fill factor tuned for volatile tables where needed | 1 | | |

### 14.3 Concurrency (Blocking & Deadlocks)

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 14.3.1 | Blocking monitored and root causes addressed | 1 | | |
| 14.3.2 | Deadlocks captured (Extended Events) and resolved | 1 | | |
| 14.3.3 | Appropriate isolation level / RCSI or snapshot isolation considered | 1 | | |
| 14.3.4 | Long transactions avoided; batch large operations | 1 | | |
| 14.3.5 | Lock escalation understood and mitigated where problematic | 1 | | |
| 14.3.6 | Reporting workloads isolated from write workloads (read replicas) where possible | 1 | | |

### 14.4 tempdb & Resource Management

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 14.4.1 | tempdb sized and file-configured correctly (SQL Server/MI) | 1 | | |
| 14.4.2 | tempdb contention monitored and mitigated | 1 | | |
| 14.4.3 | Resource Governor used where workload isolation is required (where supported) | 1 | | |
| 14.4.4 | MAXDOP and cost threshold for parallelism set deliberately | 1 | | |
| 14.4.5 | Memory grants monitored (no excessive spills to tempdb) | 1 | | |

### 14.5 Statistics & Parameterization

| # | Checklist Item | Cat | Score | Notes / Evidence |
|---|---------------|-----|-------|------------------|
| 14.5.1 | Statistics kept current (auto-update on, plus manual updates after large loads) | 1 | | |
| 14.5.2 | Auto-create statistics enabled where appropriate | 1 | | |
| 14.5.3 | Parameter sniffing issues identified and mitigated (OPTIMIZE FOR, recompile, etc.) | 1 | | |
| 14.5.4 | Plan cache health reviewed (no excessive single-use plans / bloat) | 1 | | |
| 14.5.5 | Query Store used to force stable plans where regressions occur | 1 | | |

---

## Checklist Statistics

| Area | Categories | Items | Cat 1 (Automated) | Cat 2 (Admin Review) | Cat 3 (Client Doc) |
|------|-----------|-------|--------------------|----------------------|--------------------|
| 1. Architecture & Design | 3 | 24 | 11 | 1 | 12 |
| 2. Data Integration & ETL | 4 | 25 | 24 | 0 | 1 |
| 3. T-SQL Code Quality | 3 | 19 | 19 | 0 | 0 |
| 4. Data Modeling & Storage | 5 | 35 | 34 | 0 | 1 |
| 5. Data Quality Framework | 4 | 30 | 26 | 0 | 4 |
| 6. Security & Access Control | 4 | 26 | 12 | 12 | 2 |
| 7. Compliance & Regulatory | 4 | 25 | 6 | 2 | 17 |
| 8. Data Governance | 3 | 15 | 4 | 1 | 10 |
| 9. Reliability & Resilience | 4 | 28 | 16 | 4 | 8 |
| 10. Monitoring & Observability | 4 | 21 | 17 | 2 | 2 |
| 11. DevOps & Deployment | 4 | 23 | 15 | 4 | 4 |
| 12. Cost Management & Capacity | 2 | 12 | 5 | 3 | 4 |
| 13. Documentation & Knowledge Mgmt | 4 | 16 | 0 | 0 | 16 |
| 14. Performance & Query Tuning | 5 | 29 | 29 | 0 | 0 |
| **Total** | **53** | **328** | **218** | **29** | **81** |

