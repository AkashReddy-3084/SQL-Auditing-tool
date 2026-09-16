# Failover Behaviour — AdventureWorks Data Platform

| Field | Value |
| --- | --- |
| Document version | 1.4 |
| Status | Approved as a *procedure*; **the procedure has never been tested** |
| Approved by | Data Platform Engineering, change record CHG-2026-0388 |
| Last reviewed | 2026-08-19 |
| Owner | Priya Raman, Data Platform Engineering |

## 1. Availability position

`(localdb)\MSSQLLocalDB` is a **single-node SQL Server 2025 Express instance**. It has:

- no availability group and no listener,
- no failover cluster instance,
- no readable secondary or log-shipped standby,
- no automatic failover of any kind.

Express does not support these features, and the platform was deliberately sized without them
(see [deployment-model.md](../architecture/deployment-model.md) section 3).

## 2. What happens on failure

There is no failover. Recovery is a **manual rebuild**:

| Step | Action | Expected duration |
| --- | --- | --- |
| 1 | Confirm the host `MAQN2000` is reachable and the LocalDB instance has stopped | 5 min |
| 2 | `sqllocaldb stop MSSQLLocalDB` then `sqllocaldb start MSSQLLocalDB` | 2 min |
| 3 | If the database is unrecoverable, drop it and redeploy the schema from source control | 10 min |
| 4 | Reload from the most recent `D:\dw-extracts` nightly export | 10 min |
| 5 | Notify analysts that any changes since the last nightly export are lost | 2 min |

Stated recovery objective: **RTO 30 minutes, RPO 24 hours** (one nightly export).

## 3. Testing status — THIS IS THE GAP

> **No failover or recovery test has ever been performed against this platform.**

| Question | Answer |
| --- | --- |
| Date of last failover test | **Never — no test has ever been run** |
| Date of last restore/rebuild rehearsal | **Never** |
| Has the 30-minute RTO been measured? | **No. It is an estimate, not an observed figure.** |
| Has the nightly export ever been restored? | **No. The exports have never been read back.** |
| Test schedule | **None defined** |
| Test evidence / run records | **None exist** |

The steps in section 2 are written down but entirely unproven. Nobody has confirmed that the export
files are complete, restorable, or that the schema redeploy succeeds against an empty instance.

## 4. Known risk

Because the procedure is untested, the stated RTO and RPO carry no confidence. The first real
execution of this runbook would also be its first rehearsal.

## 5. Change history

| Version | Date | Change |
| --- | --- | --- |
| 1.4 | 2026-08-19 | Reviewed; testing status still "never tested" |
| 1.3 | 2026-04-02 | Added RTO/RPO estimates |
| 1.0 | 2025-11-20 | Initial manual rebuild procedure |
