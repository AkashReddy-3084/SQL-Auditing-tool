/* Checklist 9.3.4 - ETL is idempotent - safe to re-run after failure
   Scope: DATABASE. Strictly read-only: catalog views only, no data or schema modification.
   Proxy assessment of SQL-resident ETL/load modules for re-run safety patterns. */

SET NOCOUNT ON;

DECLARE @DatabaseQueried nvarchar(max) = NULL,
        @Finding nvarchar(max) = NULL,
        @Result nvarchar(50) = NULL,
        @Score int = 0;

DECLARE @IsAzureDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL
    DROP TABLE #Databases;

IF OBJECT_ID('tempdb..#EtlModules') IS NOT NULL
    DROP TABLE #EtlModules;

CREATE TABLE #Databases
(
    DbName sysname NOT NULL PRIMARY KEY
);

CREATE TABLE #EtlModules
(
    DbName            sysname       NOT NULL,
    ObjectName        nvarchar(520) NOT NULL,
    ObjectType        nvarchar(60)  NOT NULL,
    HasMerge          bit NOT NULL,
    HasTruncateReload bit NOT NULL,
    HasExistenceGuard bit NOT NULL,
    HasDeleteReload   bit NOT NULL,
    HasWatermark      bit NOT NULL
);

IF @IsAzureDb = 1
BEGIN
    INSERT INTO #Databases (DbName)
    SELECT DB_NAME()
    WHERE DB_NAME() <> N'master';
END
ELSE
BEGIN
    INSERT INTO #Databases (DbName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = N'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;
END

IF NOT EXISTS (SELECT 1 FROM #Databases)
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    SELECT
        @Result AS Result,
        @Score AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding AS Finding;
END
ELSE
BEGIN
    DECLARE @DbName sysname,
            @Prefix nvarchar(300),
            @Sql nvarchar(max);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT DbName FROM #Databases ORDER BY DbName;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Prefix = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;

        SET @Sql = N'
INSERT INTO #EtlModules (DbName, ObjectName, ObjectType, HasMerge, HasTruncateReload, HasExistenceGuard, HasDeleteReload, HasWatermark)
SELECT
    @db,
    QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name),
    o.type_desc,
    CASE WHEN d.def LIKE N''%merge%'' AND d.def LIKE N''%using%'' THEN 1 ELSE 0 END,
    CASE WHEN d.def LIKE N''%truncate table%'' THEN 1 ELSE 0 END,
    CASE WHEN d.def LIKE N''%not exists%'' THEN 1 ELSE 0 END,
    CASE WHEN d.def LIKE N''%delete%'' AND d.def LIKE N''%insert%'' THEN 1 ELSE 0 END,
    CASE WHEN d.def LIKE N''%watermark%''
           OR d.def LIKE N''%high water%''
           OR d.def LIKE N''%last[_]load%''
           OR d.def LIKE N''%lastload%''
           OR d.def LIKE N''%incremental%''
           OR d.def LIKE N''%last[_]run[_]date%''
         THEN 1 ELSE 0 END
FROM ' + @Prefix + N'sys.sql_modules AS m
INNER JOIN ' + @Prefix + N'sys.objects AS o ON o.object_id = m.object_id
INNER JOIN ' + @Prefix + N'sys.schemas AS s ON s.schema_id = o.schema_id
CROSS APPLY (SELECT CAST(m.definition AS nvarchar(max)) COLLATE Latin1_General_CI_AI AS def) AS d
WHERE o.is_ms_shipped = 0
  AND o.type IN (''P'', ''TR'')
  AND (
        o.name COLLATE Latin1_General_CI_AI LIKE N''%etl%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%load%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%import%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%ingest%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%extract%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%transform%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%stage%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%staging%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%stg[_]%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%upsert%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%sync%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%populate%''
     OR o.name COLLATE Latin1_General_CI_AI LIKE N''%refresh%''
     OR s.name COLLATE Latin1_General_CI_AI IN (N''etl'', N''stg'', N''staging'', N''load'', N''import'', N''ods'', N''edw'', N''dw'')
      );';

        BEGIN TRY
            EXEC sys.sp_executesql @Sql, N'@db sysname', @db = @DbName;
        END TRY
        BEGIN CATCH
            /* Database not readable at this moment (offline, restoring, non-readable secondary): skip it. */
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    SET @DatabaseQueried = STUFF
    (
        (
            SELECT N', ' + DbName
            FROM #Databases
            ORDER BY DbName
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, N''
    );

    IF @DatabaseQueried IS NULL
        SET @DatabaseQueried = N'None';

    DECLARE @Total int,
            @Idempotent int,
            @Pct decimal(9, 2),
            @Risky nvarchar(max),
            @DbCount int;

    SELECT @DbCount = COUNT(*) FROM #Databases;

    SELECT
        @Total = COUNT(*),
        @Idempotent = SUM
        (
            CASE WHEN HasMerge = 1
                   OR HasTruncateReload = 1
                   OR HasExistenceGuard = 1
                   OR HasDeleteReload = 1
                   OR HasWatermark = 1
                 THEN 1 ELSE 0 END
        )
    FROM #EtlModules;

    SET @Total = ISNULL(@Total, 0);
    SET @Idempotent = ISNULL(@Idempotent, 0);
    SET @Pct = CASE WHEN @Total > 0 THEN (@Idempotent * 100.0) / @Total ELSE 0 END;

    SET @Risky = STUFF
    (
        (
            SELECT TOP (10) N', ' + DbName + N'.' + ObjectName
            FROM #EtlModules
            WHERE HasMerge = 0
              AND HasTruncateReload = 0
              AND HasExistenceGuard = 0
              AND HasDeleteReload = 0
              AND HasWatermark = 0
            ORDER BY DbName, ObjectName
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, N''
    );

    IF @Total = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No ETL/load/staging stored procedures or triggers were identified in the '
                     + CAST(@DbCount AS nvarchar(20))
                     + N' user database(s) queried. ETL may be implemented outside SQL Server (SSIS, Azure Data Factory, external tooling), so re-run safety cannot be evidenced from database metadata and must be confirmed against the ETL code and failure-recovery runbook.';
    END
    ELSE
    BEGIN
        SET @Score = CASE
                         WHEN @Pct >= 90 THEN 3
                         WHEN @Pct >= 70 THEN 2
                         WHEN @Pct >= 40 THEN 1
                         ELSE 0
                     END;

        SET @Finding = N'Identified ' + CAST(@Total AS nvarchar(20)) + N' ETL/load module(s) across '
                     + CAST(@DbCount AS nvarchar(20)) + N' user database(s); '
                     + CAST(@Idempotent AS nvarchar(20)) + N' (' + CAST(@Pct AS nvarchar(20))
                     + N'%) implement a re-run safe pattern (MERGE/USING, TRUNCATE reload, NOT EXISTS guard, DELETE+INSERT reload or watermark predicate). '
                     + CASE
                           WHEN @Risky IS NULL THEN N'No ETL module lacks an idempotency pattern.'
                           ELSE N'Module(s) with no detected idempotency pattern (first 10): ' + @Risky
                                + N'. These would duplicate or double-apply rows if re-run after a failure.'
                       END;
    END

    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    SELECT
        @Result AS Result,
        @Score AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding AS Finding;
END

IF OBJECT_ID('tempdb..#EtlModules') IS NOT NULL
    DROP TABLE #EtlModules;

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL
    DROP TABLE #Databases;