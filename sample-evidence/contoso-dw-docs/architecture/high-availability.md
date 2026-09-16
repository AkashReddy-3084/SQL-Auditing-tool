# High Availability and Failover — Contoso Data Warehouse

**Version:** 1.6
**Last reviewed:** 2026-08-28
**Owner:** Data Platform Team

## 1. Configuration

`VRSVPSQL1C` is a **standalone instance**. It is not part of an Always On availability group,
is not failover-clustered, and does not use database mirroring or log shipping.

## 2. Connection endpoints

Applications and Power BI connect **directly to the instance name** `vrsvpsql1c.contoso.local`.

There is **no SQL Server client alias, no availability group listener and no DNS CNAME** in front
of the instance. Connection strings name the server directly. Because there is no alias or
listener layer, there is nothing to resolve, redirect or repoint — clients reach the one instance
that exists.

## 3. Failover behaviour

In the event of a total instance loss, recovery is a **restore operation, not a failover**:

1. The infrastructure team provisions a replacement host from the standard SQL Server 2022 image.
2. The most recent full backup plus differential and log backups are restored from
   `\\contoso-backup\sql\VRSVPSQL1C`.
3. SQL Agent jobs and logins are reapplied from the scripted baseline in the DBA share.
4. The host is renamed to `vrsvpsql1c` so existing connection strings resolve without change.

Expected recovery time is approximately 6 hours, dominated by the restore of `ContosoDW`.

## 4. Scope note

Because no availability group, cluster or alias layer exists, transparent client reconnection on
failover is not a property this platform has or is designed to have. Recovery is a planned manual
rebuild as described above.
