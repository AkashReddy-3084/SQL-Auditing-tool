SET NOCOUNT ON;

DECLARE @DatabaseQueried sysname = DB_NAME();
DECLARE @Result NVARCHAR(50);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#EtlModules') IS NOT NULL
    DROP TABLE #EtlModules;

CREATE TABLE #EtlModules
(
    SchemaName     sysname       NOT NULL,
    ObjectName     sysname       NOT NULL,
    ObjectType     NVARCHAR(60)  NOT NULL,
    HasIdempotency BIT           NOT NULL,
    Patterns       NVARCHAR(400) NULL
);

INSERT INTO #EtlModules (SchemaName, ObjectName, ObjectType, HasIdempotency, Patterns)
SELECT
    SCHEMA_NAME(o.schema_id),
    o.name,
    CASE o.type WHEN 'P' THEN N'Stored Procedure' WHEN 'TR' THEN N'Trigger' ELSE N'Module' END,
    CASE
        WHEN (f.HasMerge + f.HasNotExists + f.HasTruncate + f.HasDeleteInsert + f.HasWatermark + f.HasHash) > 0
        THEN 1 ELSE 0
    END,
    STUFF(
          CASE WHEN f.HasMerge        = 1 THEN N', MERGE upsert'              ELSE N'' END
        + CASE WHEN f.HasNotExists    = 1 THEN N', NOT EXISTS guard'          ELSE N'' END
        + CASE WHEN f.HasTruncate     = 1 THEN N', TRUNCATE full reload'      ELSE N'' END
        + CASE WHEN f.HasDeleteInsert = 1 THEN N', DELETE-then-INSERT reload' ELSE N'' END
        + CASE WHEN f.HasWatermark    = 1 THEN N', watermark/incremental key' ELSE N'' END
        + CASE WHEN f.HasHash         = 1 THEN N', hash/checksum change detection' ELSE N'' END
        , 1, 2, N'')
FROM sys.objects AS o
INNER JOIN sys.sql_modules AS m
    ON m.object_id = o.object_id
CROSS APPLY (SELECT LOWER(m.definition) AS defn) AS l
CROSS APPLY (SELECT LOWER(o.name) AS objname, LOWER(SCHEMA_NAME(o.schema_id)) AS schname) AS n
CROSS APPLY
(
    SELECT
        CASE WHEN CHARINDEX(N'merge ', l.defn) > 0 THEN 1 ELSE 0 END AS HasMerge,
        CASE WHEN CHARINDEX(N'not exists', l.defn) > 0 THEN 1 ELSE 0 END AS HasNotExists,
        CASE WHEN CHARINDEX(N'truncate table', l.defn) > 0 THEN 1 ELSE 0 END AS HasTruncate,
        CASE WHEN CHARINDEX(N'delete from', l.defn) > 0 THEN 1 ELSE 0 END AS HasDeleteInsert,
        CASE WHEN CHARINDEX(N'watermark', l.defn) > 0
                  OR CHARINDEX(N'high_water', l.defn) > 0
                  OR CHARINDEX(N'highwater', l.defn) > 0
                  OR CHARINDEX(N'last_load', l.defn) > 0
                  OR CHARINDEX(N'lastload', l.defn) > 0
                  OR CHARINDEX(N'last_run', l.defn) > 0
                  OR CHARINDEX(N'lastrun', l.defn) > 0
                  OR CHARINDEX(N'incremental', l.defn) > 0
             THEN 1 ELSE 0 END AS HasWatermark,
        CASE WHEN CHARINDEX(N'hashbytes', l.defn) > 0
                  OR CHARINDEX(N'checksum', l.defn) > 0
                  OR CHARINDEX(N'rowversion', l.defn) > 0
             THEN 1 ELSE 0 END AS HasHash
) AS f
WHERE o.is_ms_shipped = 0
  AND o.type IN ('P', 'TR')
  AND
  (
        CHARINDEX(N'etl',       n.objname) > 0
     OR CHARINDEX(N'load',      n.objname) > 0
     OR CHARINDEX(N'import',    n.objname) > 0
     OR CHARINDEX(N'stag',      n.objname) > 0
     OR CHARINDEX(N'ingest',    n.objname) > 0
     OR CHARINDEX(N'sync',      n.objname) > 0
     OR CHARINDEX(N'extract',   n.objname) > 0
     OR CHARINDEX(N'transform', n.objname) > 0
     OR CHARINDEX(N'upsert',    n.objname) > 0
     OR CHARINDEX(N'merge',     n.objname) > 0
     OR CHARINDEX(N'refresh',   n.objname) > 0
     OR CHARINDEX(N'populate',  n.objname) > 0
     OR CHARINDEX(N'etl',       n.schname) > 0
     OR CHARINDEX(N'stag',      n.schname) > 0
     OR CHARINDEX(N'load',      n.schname) > 0
  );

DECLARE @EtlModuleCount  INT = 0;
DECLARE @IdempotentCount INT = 0;

SELECT
    @EtlModuleCount  = COUNT(*),
    @IdempotentCount = ISNULL(SUM(CAST(HasIdempotency AS INT)), 0)
FROM #EtlModules;

DECLARE @UserTableCount INT =
(
    SELECT COUNT(*)
    FROM sys.tables AS t
    WHERE t.is_ms_shipped = 0
);

DECLARE @TablesWithUniqueKey INT =
(
    SELECT COUNT(DISTINCT t.object_id)
    FROM sys.tables AS t
    INNER JOIN sys.indexes AS i
        ON i.object_id = t.object_id
    WHERE t.is_ms_shipped = 0
      AND i.is_unique = 1
);

DECLARE @ControlTableCount INT =
(
    SELECT COUNT(*)
    FROM sys.tables AS t
    CROSS APPLY (SELECT LOWER(t.name) AS tname) AS n
    WHERE t.is_ms_shipped = 0
      AND
      (
            CHARINDEX(N'watermark',    n.tname) > 0
         OR CHARINDEX(N'loadlog',      n.tname) > 0
         OR CHARINDEX(N'load_log',     n.tname) > 0
         OR CHARINDEX(N'runlog',       n.tname) > 0
         OR CHARINDEX(N'run_log',      n.tname) > 0
         OR CHARINDEX(N'batchlog',     n.tname) > 0
         OR CHARINDEX(N'batch_log',    n.tname) > 0
         OR CHARINDEX(N'etlcontrol',   n.tname) > 0
         OR CHARINDEX(N'etl_control',  n.tname) > 0
         OR CHARINDEX(N'loadcontrol',  n.tname) > 0
         OR CHARINDEX(N'load_control', n.tname) > 0
      )
);

DECLARE @GuardPct INT =
    CASE WHEN @EtlModuleCount = 0 THEN 0
         ELSE (@IdempotentCount * 100) / @EtlModuleCount
    END;

DECLARE @KeyPct INT =
    CASE WHEN @UserTableCount = 0 THEN 0
         ELSE (@TablesWithUniqueKey * 100) / @UserTableCount
    END;

DECLARE @NonIdempotentList NVARCHAR(MAX) =
    STUFF((
        SELECT TOP (10) N', ' + QUOTENAME(e.SchemaName) + N'.' + QUOTENAME(e.ObjectName)
        FROM #EtlModules AS e
        WHERE e.HasIdempotency = 0
        ORDER BY e.SchemaName, e.ObjectName
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @IdempotentList NVARCHAR(MAX) =
    STUFF((
        SELECT TOP (5) N', ' + QUOTENAME(e.SchemaName) + N'.' + QUOTENAME(e.ObjectName)
                       + N' (' + ISNULL(e.Patterns, N'guard') + N')'
        FROM #EtlModules AS e
        WHERE e.HasIdempotency = 1
        ORDER BY e.SchemaName, e.ObjectName
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

IF @EtlModuleCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Manual review required: no ETL/load stored procedures or triggers could be identified in database ['
        + @DatabaseQueried + N']. '
        + CAST(@UserTableCount AS NVARCHAR(20)) + N' user table(s) present, of which '
        + CAST(@TablesWithUniqueKey AS NVARCHAR(20)) + N' (' + CAST(@KeyPct AS NVARCHAR(10))
        + N'%) are protected by a unique index, primary key or unique constraint; '
        + CAST(@ControlTableCount AS NVARCHAR(20)) + N' ETL control/watermark table(s) detected. '
        + N'ETL is likely orchestrated outside the database engine (SSIS, ADF, external scheduler), so re-run idempotency cannot be confirmed from the database catalog.';
END
ELSE IF @GuardPct >= 90 AND @KeyPct >= 90
BEGIN
    SET @Score = 3;
    SET @Finding = CAST(@IdempotentCount AS NVARCHAR(20)) + N' of '
        + CAST(@EtlModuleCount AS NVARCHAR(20)) + N' ETL/load module(s) in database ['
        + @DatabaseQueried + N'] (' + CAST(@GuardPct AS NVARCHAR(10))
        + N'%) implement an explicit idempotency guard, and '
        + CAST(@TablesWithUniqueKey AS NVARCHAR(20)) + N' of '
        + CAST(@UserTableCount AS NVARCHAR(20)) + N' user table(s) ('
        + CAST(@KeyPct AS NVARCHAR(10)) + N'%) enforce uniqueness, preventing duplicate rows on re-run. '
        + CAST(@ControlTableCount AS NVARCHAR(20)) + N' ETL control/watermark table(s) detected. Examples: '
        + ISNULL(@IdempotentList, N'n/a') + N'.';
END
ELSE IF @GuardPct >= 60
BEGIN
    SET @Score = 2;
    SET @Finding = N'Idempotency is only partially implemented in database [' + @DatabaseQueried + N']: '
        + CAST(@IdempotentCount AS NVARCHAR(20)) + N' of '
        + CAST(@EtlModuleCount AS NVARCHAR(20)) + N' ETL/load module(s) ('
        + CAST(@GuardPct AS NVARCHAR(10)) + N'%) contain a re-run guard, and unique-key coverage is '
        + CAST(@TablesWithUniqueKey AS NVARCHAR(20)) + N' of '
        + CAST(@UserTableCount AS NVARCHAR(20)) + N' table(s) ('
        + CAST(@KeyPct AS NVARCHAR(10)) + N'%). Modules without any guard: '
        + ISNULL(@NonIdempotentList, N'none') + N'.';
END
ELSE IF @GuardPct > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Most ETL/load modules in database [' + @DatabaseQueried
        + N'] are not re-run safe: only ' + CAST(@IdempotentCount AS NVARCHAR(20)) + N' of '
        + CAST(@EtlModuleCount AS NVARCHAR(20)) + N' module(s) ('
        + CAST(@GuardPct AS NVARCHAR(10)) + N'%) contain a MERGE, NOT EXISTS, reload or watermark guard. '
        + N'Unique-key coverage is ' + CAST(@TablesWithUniqueKey AS NVARCHAR(20)) + N' of '
        + CAST(@UserTableCount AS NVARCHAR(20)) + N' table(s) ('
        + CAST(@KeyPct AS NVARCHAR(10)) + N'%). Modules without any guard: '
        + ISNULL(@NonIdempotentList, N'none') + N'.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'None of the ' + CAST(@EtlModuleCount AS NVARCHAR(20))
        + N' ETL/load module(s) identified in database [' + @DatabaseQueried
        + N'] contain any idempotency guard (no MERGE upsert, NOT EXISTS anti-join, TRUNCATE/DELETE-then-INSERT reload, watermark predicate or hash change detection). '
        + N'Unique-key coverage is ' + CAST(@TablesWithUniqueKey AS NVARCHAR(20)) + N' of '
        + CAST(@UserTableCount AS NVARCHAR(20)) + N' table(s) ('
        + CAST(@KeyPct AS NVARCHAR(10)) + N'%), and '
        + CAST(@ControlTableCount AS NVARCHAR(20)) + N' ETL control/watermark table(s) exist. Affected modules: '
        + ISNULL(@NonIdempotentList, N'none') + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#EtlModules') IS NOT NULL
    DROP TABLE #EtlModules;