# Maintenance Windows and Patching — Contoso Data Warehouse

**Version:** 2.2
**Last reviewed:** 2026-08-12
**Owner:** Infrastructure Operations (infra-ops@contoso.example)
**Approved by:** Change Advisory Board, CAB-2026-031

## 1. Maintenance windows

| Environment | Window | Frequency | Notes |
|-------------|--------|-----------|-------|
| Production (`VRSVPSQL1C`) | Sunday 02:00–06:00 UTC | Monthly, second Sunday | Nightly ETL is suspended for the window |
| Test (`VRSVTSQL1C`) | Wednesday 18:00–22:00 UTC | Monthly, first Wednesday | Patched one week ahead of production |
| Development | No window | Ad hoc | Patched opportunistically |

Production maintenance is announced to the reporting user group seven calendar days in advance
via the `#contoso-data-platform` channel and the operations calendar.

## 2. Patching approach

This is an on-premises SQL Server deployment, so patching is Contoso's responsibility — it is not
Microsoft-managed as it would be on a PaaS platform.

1. Microsoft releases a Cumulative Update for SQL Server 2022.
2. Infrastructure Operations reviews the CU release notes within 5 working days.
3. The CU is applied to **Test** in the next test window and left to soak for one full weekly
   reporting cycle.
4. If no regression is reported, the CU is applied to **Production** in the following production
   window under a standard change record.
5. Security-rated updates bypass the soak period and are applied under an emergency change with
   CAB chair approval.

Windows Server guest OS patching follows the corporate WSUS schedule and is applied in the same
window as the SQL Server CU to avoid a second outage.

## 3. Current patch level

| Instance | SQL Server build | CU | Applied |
|----------|------------------|----|---------|
| `VRSVPSQL1C` | 16.0.4150.1 | CU14 | 2026-08-09 |
| `VRSVTSQL1C` | 16.0.4150.1 | CU14 | 2026-08-05 |

## 4. Rollback

Cumulative Updates are uninstalled through Programs and Features if a regression is confirmed
within the change window. Where the CU cannot be uninstalled cleanly, the host is restored from
the pre-change VM snapshot taken at the start of the window.

## 5. Recent maintenance record

| Date | Environment | Action | Outcome |
|------|-------------|--------|---------|
| 2026-08-09 | Production | SQL Server 2022 CU14 | Completed, no regression |
| 2026-08-05 | Test | SQL Server 2022 CU14 | Completed, soaked 4 days |
| 2026-07-12 | Production | SQL Server 2022 CU13 + OS updates | Completed |
