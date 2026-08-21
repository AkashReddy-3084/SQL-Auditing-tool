/* Checklist 2.4.1 - Bulk load patterns used (BULK INSERT / bcp / minimal logging) for large loads
   Scope: SERVER. Strictly read-only: reads catalog metadata only, makes no configuration change. */
SET NOCOUNT ON;

DECLARE @EngineEdition  INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @db             SYSNAME;
DECLARE @sql            NVARCHAR(MAX);
DECLARE @JobBulkCnt     INT = 0;
DECLARE @TotalDb        INT = 0;
DECLARE @BulkDb         INT = 0;
DECLARE @MinLogDb       INT = 0;
DECLARE @TablockDb      INT = 0;
DECLARE @BulkDbList     NVARCHAR(MAX);
DECLARE @DbQueried      NVARCHAR(MAX);
DECLARE @Result         NVARCHAR(20);
DECLARE @Score          INT;
DECLARE @Finding        NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#BulkLoad') IS NOT NULL
    DROP TABLE #BulkLoad;

CREATE TABLE #BulkLoad
(
    DatabaseName  SYSNAME      NOT NULL,
    RecoveryModel NVARCHAR(60) NULL,
    BulkInsertCnt INT          NOT NULL,
    OpenRowsetCnt INT          NOT NULL,
    BcpCnt        INT          NOT NULL,
    TablockCnt    INT          NOT NULL
);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: only the current database is reachable and msdb does not exist. */
    INSERT INTO #BulkLoad (DatabaseName, RecoveryModel, BulkInsertCnt, OpenRowsetCnt, BcpCnt, TablockCnt)
    SELECT
        DB_NAME(),
        CONVERT(NVARCHAR(60), DATABASEPROPERTYEX(DB_NAME(), 'Recovery')),
        ISNULL(SUM(CASE WHEN m.[definition] LIKE '%BULK INSERT%' THEN 1 ELSE 0 END), 0),
        ISNULL(SUM(CASE WHEN m.[definition] LIKE '%OPENROWSET%' AND m.[definition] LIKE '%BULK%' THEN 1 ELSE 0 END), 0),
        ISNULL(SUM(CASE WHEN m.[definition] LIKE '%bcp %' OR m.[definition] LIKE '%bcp.exe%' THEN 1 ELSE 0 END), 0),
        ISNULL(SUM(CASE WHEN m.[definition] LIKE '%TABLOCK%' THEN 1 ELSE 0 END), 0)
    FROM sys.sql_modules AS m;
END
ELSE
BEGIN
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N'SELECT @p_db,
       CONVERT(NVARCHAR(60), DATABASEPROPERTYEX(@p_db, ''Recovery'')),
       ISNULL(SUM(CASE WHEN m.[definition] LIKE ''%BULK INSERT%'' THEN 1 ELSE 0 END), 0),
       ISNULL(SUM(CASE WHEN m.[definition] LIKE ''%OPENROWSET%'' AND m.[definition] LIKE ''%BULK%'' THEN 1 ELSE 0 END), 0),
       ISNULL(SUM(CASE WHEN m.[definition] LIKE ''%bcp %'' OR m.[definition] LIKE ''%bcp.exe%'' THEN 1 ELSE 0 END), 0),
       ISNULL(SUM(CASE WHEN m.[definition] LIKE ''%TABLOCK%'' THEN 1 ELSE 0 END), 0)
FROM ' + QUOTENAME(@db) + N'.sys.sql_modules AS m;';

            INSERT INTO #BulkLoad (DatabaseName, RecoveryModel, BulkInsertCnt, OpenRowsetCnt, BcpCnt, TablockCnt)
            EXEC sp_executesql @sql, N'@p_db SYSNAME', @p_db = @db;
        END TRY
        BEGIN CATCH
            /* Database unreadable for this login - record it so the scope stays visible. */
            INSERT INTO #BulkLoad (DatabaseName, RecoveryModel, BulkInsertCnt, OpenRowsetCnt, BcpCnt, TablockCnt)
            VALUES (@db, CONVERT(NVARCHAR(60), DATABASEPROPERTYEX(@db, 'Recovery')), 0, 0, 0, 0);
        END CATCH

        FETCH NEXT FROM db_cur INTO @db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;

    BEGIN TRY
        SELECT @JobBulkCnt = COUNT(DISTINCT js.job_id)
        FROM msdb.dbo.sysjobsteps AS js
        WHERE js.command LIKE '%BULK INSERT%'
           OR js.command LIKE '%bcp %'
           OR js.command LIKE '%bcp.exe%'
           OR (js.command LIKE '%OPENROWSET%' AND js.command LIKE '%BULK%')
           OR js.subsystem = 'SSIS';
    END TRY
    BEGIN CATCH
        SET @JobBulkCnt = 0;
    END CATCH
END

SELECT @TotalDb = COUNT(*) FROM #BulkLoad;

SELECT @BulkDb = COUNT(*)
FROM #BulkLoad
WHERE BulkInsertCnt + OpenRowsetCnt + BcpCnt > 0;

SELECT @MinLogDb = COUNT(*)
FROM #BulkLoad
WHERE BulkInsertCnt + OpenRowsetCnt + BcpCnt > 0
  AND UPPER(ISNULL(RecoveryModel, N'')) IN (N'SIMPLE', N'BULK_LOGGED');

SELECT @TablockDb = COUNT(*)
FROM #BulkLoad
WHERE TablockCnt > 0;

SELECT @BulkDbList = STUFF((
        SELECT N', ' + b.DatabaseName + N' [' + ISNULL(b.RecoveryModel, N'UNKNOWN') + N']'
        FROM #BulkLoad AS b
        WHERE b.BulkInsertCnt + b.OpenRowsetCnt + b.BcpCnt > 0
        ORDER BY b.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SELECT @DbQueried = STUFF((
        SELECT N', ' + b.DatabaseName
        FROM #BulkLoad AS b
        ORDER BY b.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

IF @DbQueried IS NULL
    SET @DbQueried = N'None (no accessible user databases)';

IF (@BulkDb > 0 OR @JobBulkCnt > 0) AND @MinLogDb > 0
    SET @Score = 3;
ELSE IF (@BulkDb > 0 OR @JobBulkCnt > 0)
    SET @Score = 2;
ELSE
    SET @Score = 1;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
      N'Scanned ' + CAST(@TotalDb AS NVARCHAR(10)) + N' user database(s). '
    + CAST(@BulkDb AS NVARCHAR(10)) + N' database(s) contain bulk-load code (BULK INSERT / OPENROWSET(BULK) / bcp)'
    + CASE WHEN @BulkDbList IS NOT NULL THEN N': ' + @BulkDbList ELSE N'' END + N'. '
    + CAST(@MinLogDb AS NVARCHAR(10)) + N' of those run under SIMPLE or BULK_LOGGED recovery (minimal logging eligible). '
    + CAST(@TablockDb AS NVARCHAR(10)) + N' database(s) reference TABLOCK in module code. '
    + CASE WHEN @EngineEdition = 5
           THEN N'SQL Agent job steps not evaluated (Azure SQL Database has no msdb job catalog).'
           ELSE CAST(@JobBulkCnt AS NVARCHAR(10)) + N' SQL Agent job(s) invoke bcp / BULK INSERT / SSIS bulk load.'
      END
    + CASE WHEN @Score = 3 THEN N' Bulk-load patterns are in use with minimal-logging-capable recovery models.'
           WHEN @Score = 2 THEN N' Bulk-load patterns are in use but every database holding them is in FULL recovery, so loads are always fully logged.'
           ELSE N' No bulk-load pattern was detected; large loads appear to rely on standard row-by-row INSERT.'
      END;

SELECT
    @Result     AS Result,
    @Score      AS Score,
    @DbQueried  AS DatabaseQueried,
    @Finding    AS Finding;