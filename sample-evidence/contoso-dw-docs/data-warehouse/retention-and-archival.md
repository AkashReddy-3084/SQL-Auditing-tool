# Retention and Archival — Contoso Data Warehouse

**Status:** DRAFT — not agreed
**Last touched:** 2025-04-17
**Owner:** unassigned

## 1. Current position

**There is no agreed historical or archival strategy for the data warehouse.**

`ContosoDW` has retained every fact row loaded since the platform went live in 2019. Nothing has
ever been archived, summarised or purged. `FactSalesLine` is now 410 GB and grows by roughly
9 GB per month.

The consequences are already visible:

- The nightly index maintenance job no longer completes inside the maintenance window.
- The full backup of `ContosoDW` takes 4h 20m and is the binding constraint on the restore RTO.
- Finance's year-on-year queries scan the full history because there is no summary layer.

## 2. What is missing

| Question | Status |
|----------|--------|
| How long must detail-level fact data be retained? | Not answered — Finance and Legal have not been asked |
| Should aged data be archived, summarised or deleted? | Not decided |
| Where would archived data live? | No target identified |
| Who owns the decision? | No owner assigned |
| Is there a partitioning or sliding-window design? | None; all fact tables are single-partition heaps/clustered indexes |

## 3. History of this document

This draft was raised as an action from the 2025 capacity review (CAP-2025-08). It was not taken
forward. It was re-raised at the 2026 capacity review and again deferred. It carries no approval
and no owner, and the 2025 figures above have not been refreshed.

> **TODO:** agree retention periods with Finance and Legal, then design the archival mechanism.
> Nobody is currently assigned to this.
