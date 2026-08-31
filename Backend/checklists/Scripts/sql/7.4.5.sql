-- Checklist 7.4.5 - Audit logs stored in a tamper-resistant location (separate store / immutable)
-- Scope: SERVER. Read-only.
SET NOCOUNT ON;

DECLARE @EngineEdition     INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result            NVARCHAR(20);
DECLARE @Score             INT = 0;
DECLARE @Finding           NVARCHAR(MAX);
DECLARE @DatabaseQueried   NVARCHAR(256) = N'N/A (Server-Level)';
DECLARE @Detail            NVARCHAR(MAX) = N'';
DECLARE @Total             INT = 0;
DECLARE @Started           INT = 0;
DECLARE @Tamper            INT = 0;
DECLARE @Weak              INT = 0;

IF OBJECT_ID('tempdb..#AuditTargets') IS NOT NULL
    DROP TABLE #AuditTargets;

CREATE TABLE #AuditTargets
(
    AuditName      SYSNAME       NOT NULL,
    AuditType      NVARCHAR(60)  NULL,
    LogPath        NVARCHAR(512) NULL,
    AuditState     NVARCHAR(60)  NULL,
    OnFailure      NVARCHAR(60)  NULL,
    Classification NVARCHAR(30)  NOT NULL
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: auditing is configured on the logical server / database outside the engine.
    SET @Score = 1;
    SET @Finding = N'Azure SQL Database (EngineEdition 5) detected. SQL Server Audit destinations are not exposed through sys.server_audits on this platform, so the storage location cannot be classified from T-SQL. Manually confirm in the Azure portal that auditing writes to a dedicated storage account, Log Analytics workspace or Event Hub outside this logical server, and that immutability (WORM policy / legal hold) and restrictive RBAC are enabled on that target.';
END
ELSE
BEGIN
    DECLARE @sql NVARCHAR(MAX) = N'
    INSERT INTO #AuditTargets (AuditName, AuditType, LogPath, AuditState, OnFailure, Classification)
    SELECT
        sa.name,
        sa.type_desc,
        ISNULL(sfa.log_file_path, N''''),
        ISNULL(sas.status_desc, N''NOT STARTED''),
        ISNULL(sa.on_failure_desc, N''UNKNOWN''),
        CASE
            WHEN sa.type_desc = N''SECURITY LOG''
                THEN N''TamperResistant''
            WHEN sa.type_desc = N''FILE''
                 AND LEFT(ISNULL(sfa.log_file_path, N''''), 2) = N''\\''
                THEN N''TamperResistant''
            WHEN sa.type_desc = N''FILE''
                 AND (ISNULL(sfa.log_file_path, N'''') LIKE N''http://%''
                      OR ISNULL(sfa.log_file_path, N'''') LIKE N''https://%'')
                THEN N''TamperResistant''
            ELSE N''Weak''
        END
    FROM sys.server_audits AS sa
    LEFT JOIN sys.server_file_audits AS sfa
        ON sfa.audit_id = sa.audit_id
    LEFT JOIN sys.dm_server_audit_status AS sas
        ON sas.audit_id = sa.audit_id;';

    EXEC sys.sp_executesql @sql;

    SELECT
        @Total   = COUNT(*),
        @Started = ISNULL(SUM(CASE WHEN AuditState = N'STARTED' THEN 1 ELSE 0 END), 0),
        @Tamper  = ISNULL(SUM(CASE WHEN AuditState = N'STARTED' AND Classification = N'TamperResistant' THEN 1 ELSE 0 END), 0),
        @Weak    = ISNULL(SUM(CASE WHEN AuditState = N'STARTED' AND Classification = N'Weak' THEN 1 ELSE 0 END), 0)
    FROM #AuditTargets;

    IF @Total > 0
    BEGIN
        SET @Detail = ISNULL(STUFF((
            SELECT N'; ' + t.AuditName
                   + N' [type=' + ISNULL(t.AuditType, N'UNKNOWN')
                   + N'; state=' + ISNULL(t.AuditState, N'UNKNOWN')
                   + N'; target=' + CASE WHEN LEN(ISNULL(t.LogPath, N'')) > 0 THEN t.LogPath ELSE N'(no file path)' END
                   + N'; on_failure=' + ISNULL(t.OnFailure, N'UNKNOWN')
                   + N'; classification=' + t.Classification + N']'
            FROM #AuditTargets AS t
            ORDER BY t.AuditName
            FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'');
    END

    IF @Total = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No SQL Server Audit objects are defined on this instance, so no audit log is being written to any store, tamper-resistant or otherwise.';
    END
    ELSE IF @Started = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'All ' + CAST(@Total AS NVARCHAR(10)) + N' defined SQL Server Audit(s) are stopped, so no audit records are reaching any storage target. Audits found: ' + @Detail;
    END
    ELSE IF @Weak = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All ' + CAST(@Started AS NVARCHAR(10)) + N' running SQL Server Audit(s) write to a tamper-resistant destination (Windows Security Log, UNC share, or blob/URL endpoint) held outside the local instance file system. Audits found: ' + @Detail;
    END
    ELSE IF @Tamper > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Mixed audit storage: ' + CAST(@Tamper AS NVARCHAR(10)) + N' of ' + CAST(@Started AS NVARCHAR(10)) + N' running audit(s) use a tamper-resistant destination while ' + CAST(@Weak AS NVARCHAR(10)) + N' write to a locally writable location (local drive or Windows Application Log) that a server administrator can alter or delete. Audits found: ' + @Detail;
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = N'All ' + CAST(@Started AS NVARCHAR(10)) + N' running SQL Server Audit(s) write to a locally writable destination (local drive path or Windows Application Log) on the same host as the database engine, so audit records are not held in a separate or immutable store. Audits found: ' + @Detail;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#AuditTargets') IS NOT NULL
    DROP TABLE #AuditTargets;