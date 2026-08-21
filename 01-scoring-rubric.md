# Scoring Rubric — MLC SQL (SQL Server / Azure SQL Data Warehouse) Audit

## 1. Per-Checklist-Item Scoring (0–3)

Each checklist item is scored independently by the auditor based on evidence gathered during the audit.

| Score | Label | Definition | Evidence Required |
|-------|-------|------------|-------------------|
| **0** | Not Implemented | Capability is completely absent. Represents a critical gap or active risk. | Documented absence — screenshot, config/DMV query, or stakeholder confirmation |
| **1** | Partially Implemented | Capability exists but has major gaps, inconsistencies, or introduces risk. | Evidence of partial implementation with noted gaps |
| **2** | Implemented | Capability is functional with only minor issues or improvement opportunities. | Evidence of working implementation; note minor gaps |
| **3** | Best Practice | Fully implemented following SQL Server / Azure SQL and industry best practices. | Evidence of implementation + alignment with documented best practice |
| **N/A** | Not Applicable | Item does not apply to this solution. Excluded from all score calculations. | Written justification for exclusion |

### Scoring Guidelines

- **Default to 0** if no evidence can be found. Absence of evidence is evidence of absence.
- **Score 1** requires the auditor to observe *some* implementation, even if incomplete.
- **Score 2** is the "it works" baseline — functional but not optimized.
- **Score 3** requires the auditor to verify alignment with a specific best practice reference.
- **Use N/A sparingly** — every N/A should have a written justification (e.g., a feature only available in one deployment model).

---

## 2. Category Score Calculation

```
Category Score = (Sum of applicable item scores) / (3 × Count of applicable items) × 100%
```

Items marked N/A are excluded from both numerator and denominator.

---

## 3. Area Score Calculation

```
Area Score = Average of all category scores within the area
```

Auditors may override with custom category weights; document any overrides in the report.

---

## 4. Overall Health Score

```
Overall Score = Σ (Area Score × Area Weight)
```

### Area Weights (MLC SQL)

| # | Area | Weight | Rationale |
|---|------|--------|-----------|
| 1 | Architecture & Design | 8% | DW topology (staging/ODS/DW/marts), deployment model, HA design |
| 2 | Data Integration & ETL | 10% | Core ETL/ELT function (SSIS / ADF / T-SQL) |
| 3 | T-SQL Code Quality | 8% | Stored procedures, set-based logic, error handling |
| 4 | Data Modeling & Storage | 9% | Normalization/star, indexing, partitioning, keys, statistics |
| 5 | Data Quality Framework | 9% | Cross-cutting data trust and analytical correctness |
| 6 | Security & Access Control | 12% | Logins/roles, TDE, Always Encrypted, DDM, RLS, network |
| 7 | Compliance & Regulatory | 7% | Regime TBD — generic ITGC + audit trail + privacy placeholder |
| 8 | Data Governance | 4% | Cataloging, lineage, ownership |
| 9 | Reliability & Resilience | 6% | Backups, PITR, Always On AG, failover, integrity checks |
| 10 | Monitoring & Observability | 5% | Query Store, DMVs, Extended Events, alerts |
| 11 | DevOps & Deployment | 6% | SSDT/DACPAC, migrations, CI/CD |
| 12 | Cost Management & Capacity | 4% | DTU/vCore sizing, elastic pools, storage |
| 13 | Documentation & Knowledge Mgmt | 3% | Operational risk and maintainability |
| 14 | Performance & Query Tuning | 9% | Execution plans, index tuning, blocking/deadlocks, tempdb |
| | **Total** | **100%** | |

### Adjusting Weights

- Once MLC's **compliance regime** is confirmed, increase Area 7 and rebalance.
- For **OLTP-heavy** solutions, increase Areas 14 (Performance) and 9 (Reliability).
- For **pure analytical DW** solutions, increase Areas 4 (Modeling) and 2 (ETL).
- Always ensure weights sum to 100%; document adjustments in the report.

---

## 5. Risk Rating Bands

| Score Range | Rating | Icon | Action Required |
|-------------|--------|------|-----------------|
| 0–40% | Critical | 🔴 | Immediate remediation required; production readiness at risk |
| 41–60% | High | 🟠 | Significant gaps that must be prioritized; risk of incidents |
| 61–75% | Medium | 🟡 | Functional but needs targeted improvement |
| 76–90% | Good | 🟢 | Minor improvements recommended; generally healthy |
| 91–100% | Excellent | 🔵 | Best-practice compliant; maintain and monitor |

---

## 6. Severity Classification for Individual Findings

| Severity | Definition | SLA for Remediation |
|----------|------------|---------------------|
| **Critical** | Active security vulnerability, compliance violation, or data loss risk | Immediate (0–7 days) |
| **High** | Significant gap that will likely cause issues if not addressed | 30 days |
| **Medium** | Improvement opportunity that reduces risk or improves efficiency | 90 days |
| **Low** | Best-practice recommendation; nice-to-have | Next planning cycle |
| **Informational** | Observation with no immediate action required | No SLA |

---

## 7. Score Aggregation Template

### Area: [Area Name]

| Category | Items | Applicable | Total Score | Max Score | Category % | Rating |
|----------|-------|------------|-------------|-----------|------------|--------|
| [Category 1] | X | Y | Z | 3×Y | Z/(3×Y)×100 | 🔴🟠🟡🟢🔵 |
| **Area Total** | | | | | **Avg of above** | |

### Overall Summary

| # | Area | Weight | Score | Weighted Score | Rating |
|---|------|--------|-------|----------------|--------|
| 1 | Architecture & Design | 8% | | | |
| 2 | Data Integration & ETL | 10% | | | |
| 3 | T-SQL Code Quality | 8% | | | |
| 4 | Data Modeling & Storage | 9% | | | |
| 5 | Data Quality Framework | 9% | | | |
| 6 | Security & Access Control | 12% | | | |
| 7 | Compliance & Regulatory | 7% | | | |
| 8 | Data Governance | 4% | | | |
| 9 | Reliability & Resilience | 6% | | | |
| 10 | Monitoring & Observability | 5% | | | |
| 11 | DevOps & Deployment | 6% | | | |
| 12 | Cost Management & Capacity | 4% | | | |
| 13 | Documentation & Knowledge Mgmt | 3% | | | |
| 14 | Performance & Query Tuning | 9% | | | |
| | **Overall Health Score** | **100%** | | | |

