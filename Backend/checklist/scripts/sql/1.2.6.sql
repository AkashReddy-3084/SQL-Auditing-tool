/* Checklist 1.2.6 - Audit metadata captured on load (load_date, source_system, batch_id)
   Read-only: catalog metadata only, no user data is read and nothing is modified. */
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID('tempdb..#Col') IS NOT NULL DROP TABLE #Col;
IF OBJECT_ID('tempdb..#Tbl') IS NOT NULL DROP TABLE #Tbl;
IF OBJECT_ID('tempdb..#Flag') IS NOT NULL DROP TABLE #Flag;
IF OBJECT_ID('tempdb..#Skipped') IS NOT NULL DROP TABLE #Skipped;

CREATE TABLE #Db (DatabaseName sysname NOT NULL PRIMARY KEY);
CREATE TABLE #Tbl (DatabaseName sysname NOT NULL, SchemaName sysname NOT NULL, TableName sysname NOT NULL);
CREATE TABLE #Col (DatabaseName sysname NOT NULL, SchemaName sysname NOT NULL, TableName sysname NOT NULL, NormName nvarchar(256) NOT NULL);
CREATE TABLE #Flag (DatabaseName sysname NOT NULL, SchemaName sysname NOT NULL, TableName sysname NOT NULL,
                    HasLoadDate bit NOT NULL, HasSourceSystem bit NOT NULL, HasBatchId bit NOT NULL);
CREATE TABLE #Skipped (DatabaseName sysname NOT NULL, ErrMsg nvarchar(2048) NULL);

IF @IsAzureSqlDb = 1
    INSERT INTO #Db (DatabaseName) SELECT DB_NAME();
ELSE
    INSERT INTO #Db (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.name NOT IN ('SSISDB', 'distribution', 'ReportServer', 'ReportServerTempDB')
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @DbName sysname, @Sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR SELECT DatabaseName FROM #Db ORDER BY DatabaseName;
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
        INSERT INTO #Tbl (DatabaseName, SchemaName, TableName)
        SELECT @Db, s.name, t.name
        FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
        INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
          AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'');

        INSERT INTO #Col (DatabaseName, SchemaName, TableName, NormName)
        SELECT @Db, s.name, t.name, REPLACE(REPLACE(LOWER(c.name), ''_'', ''''), '' '', '''')
        FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
        INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
        INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.columns AS c ON c.object_id = t.object_id
        WHERE t.is_ms_shipped = 0
          AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
          AND (c.name LIKE ''%load%'' OR c.name LIKE ''%source%'' OR c.name LIKE ''%src%''
               OR c.name LIKE ''%batch%'' OR c.name LIKE ''%insert%'' OR c.name LIKE ''%creat%''
               OR c.name LIKE ''%etl%'' OR c.name LIKE ''%run%'' OR c.name LIKE ''%process%''
               OR c.name LIKE ''%execution%'');';

        EXEC sys.sp_executesql @Sql, N'@Db sysname', @Db = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #Skipped (DatabaseName, ErrMsg) VALUES (@DbName, LEFT(ERROR_MESSAGE(), 2048));
    END CATCH

    FETCH NEXT FROM db_cur INTO @DbName;
END
CLOSE db_cur;
DEALLOCATE db_cur;

INSERT INTO #Flag (DatabaseName, SchemaName, TableName, HasLoadDate, HasSourceSystem, HasBatchId)
SELECT t.DatabaseName, t.SchemaName, t.TableName,
       MAX(CASE WHEN c.NormName LIKE '%loaddate%' OR c.NormName LIKE '%loaddt%' OR c.NormName LIKE '%loadtime%'
                  OR c.NormName LIKE '%loadts%'   OR c.NormName LIKE '%dateloaded%' OR c.NormName LIKE '%loadedon%'
                  OR c.NormName LIKE '%loadedat%' OR c.NormName LIKE '%insertdate%' OR c.NormName LIKE '%inserteddate%'
                  OR c.NormName LIKE '%insertedon%' OR c.NormName LIKE '%insertts%'  OR c.NormName LIKE '%createddate%'
                  OR c.NormName LIKE '%createdate%' OR c.NormName LIKE '%createdon%' OR c.NormName LIKE '%createdts%'
                  OR c.NormName LIKE '%etldate%'  OR c.NormName LIKE '%etlts%'
                THEN 1 ELSE 0 END) AS HasLoadDate,
       MAX(CASE WHEN c.NormName LIKE '%sourcesystem%' OR c.NormName LIKE '%srcsystem%' OR c.NormName LIKE '%srcsys%'
                  OR c.NormName LIKE '%recordsource%' OR c.NormName LIKE '%datasource%' OR c.NormName LIKE '%sourceapp%'
                  OR c.NormName LIKE '%sourcename%'   OR c.NormName LIKE '%sourcefile%' OR c.NormName LIKE '%sourceid%'
                  OR c.NormName LIKE '%sourcecode%'   OR c.NormName LIKE '%srcname%'    OR c.NormName LIKE '%srcid%'
                  OR c.NormName = 'source'            OR c.NormName = 'src'
                THEN 1 ELSE 0 END) AS HasSourceSystem,
       MAX(CASE WHEN c.NormName LIKE '%batchid%' OR c.NormName LIKE '%batchno%'  OR c.NormName LIKE '%batchnumber%'
                  OR c.NormName LIKE '%batchkey%' OR c.NormName LIKE '%batchguid%' OR c.NormName LIKE '%etlbatch%'
                  OR c.NormName LIKE '%loadbatch%' OR c.NormName LIKE '%loadid%'  OR c.NormName LIKE '%runid%'
                  OR c.NormName LIKE '%executionid%' OR c.NormName LIKE '%processid%' OR c.NormName LIKE '%processrunid%'
                  OR c.NormName = 'batch'
                THEN 1 ELSE 0 END) AS HasBatchId
FROM #Tbl AS t
LEFT JOIN #Col AS c
       ON c.DatabaseName = t.DatabaseName
      AND c.SchemaName   = t.SchemaName
      AND c.TableName    = t.TableName
GROUP BY t.DatabaseName, t.SchemaName, t.TableName;

DECLARE @DbCount int = (SELECT COUNT(*) FROM #Db);
DECLARE @SkipCount int = (SELECT COUNT(*) FROM #Skipped);
DECLARE @TotalTables int = 0, @FullCnt int = 0, @AnyCnt int = 0;

SELECT @TotalTables = COUNT(*),
       @FullCnt = SUM(CASE WHEN HasLoadDate = 1 AND HasSourceSystem = 1 AND HasBatchId = 1 THEN 1 ELSE 0 END),
       @AnyCnt  = SUM(CASE WHEN HasLoadDate = 1 OR  HasSourceSystem = 1 OR  HasBatchId = 1 THEN 1 ELSE 0 END)
FROM #Flag;

SET @TotalTables = ISNULL(@TotalTables, 0);
SET @FullCnt = ISNULL(@FullCnt, 0);
SET @AnyCnt = ISNULL(@AnyCnt, 0);

DECLARE @FullPct decimal(5,1) = CASE WHEN @TotalTables > 0 THEN CAST(100.0 * @FullCnt / @TotalTables AS decimal(5,1)) ELSE 0 END;
DECLARE @AnyPct  decimal(5,1) = CASE WHEN @TotalTables > 0 THEN CAST(100.0 * @AnyCnt  / @TotalTables AS decimal(5,1)) ELSE 0 END;

DECLARE @MissLoad int = (SELECT COUNT(*) FROM #Flag WHERE HasLoadDate = 0);
DECLARE @MissSource int = (SELECT COUNT(*) FROM #Flag WHERE HasSourceSystem = 0);
DECLARE @MissBatch int = (SELECT COUNT(*) FROM #Flag WHERE HasBatchId = 0);

DECLARE @DatabaseQueried nvarchar(max) = ISNULL(STUFF((
        SELECT ', ' + d.DatabaseName
        FROM #Db AS d
        ORDER BY d.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, ''), 'None');

DECLARE @WorstDbs nvarchar(max) = ISNULL(STUFF((
        SELECT TOP (5) ', ' + x.DatabaseName + ' (' + CAST(x.FullPct AS varchar(10)) + '% fully instrumented, '
                     + CAST(x.TableCount AS varchar(20)) + ' table(s))'
        FROM (SELECT f.DatabaseName,
                     TableCount = COUNT(*),
                     FullPct = CAST(100.0 * SUM(CASE WHEN f.HasLoadDate = 1 AND f.HasSourceSystem = 1 AND f.HasBatchId = 1 THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1))
              FROM #Flag AS f
              GROUP BY f.DatabaseName) AS x
        ORDER BY x.FullPct ASC, x.DatabaseName ASC
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, ''), 'n/a');

DECLARE @Result nvarchar(20), @Score int, @Finding nvarchar(max);

IF @DbCount = 0 OR @TotalTables = 0
    SET @Score = 0;
ELSE IF @FullPct >= 90.0
    SET @Score = 3;
ELSE IF @FullPct >= 50.0 OR @AnyPct >= 80.0
    SET @Score = 2;
ELSE
    SET @Score = 1;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
    CASE
        WHEN @DbCount = 0
            THEN 'No accessible ONLINE user database was found on this instance, so audit-metadata instrumentation of loaded tables could not be assessed. Manual review required.'
        WHEN @TotalTables = 0
            THEN 'No user tables were found in the ' + CAST(@DbCount AS varchar(20)) + ' accessible user database(s), so audit-metadata instrumentation could not be assessed. Manual review required.'
        ELSE 'Inspected ' + CAST(@TotalTables AS varchar(20)) + ' user table(s) across ' + CAST(@DbCount AS varchar(20))
             + ' database(s): ' + CAST(@FullCnt AS varchar(20)) + ' (' + CAST(@FullPct AS varchar(10))
             + '%) expose all three audit-metadata elements (load date, source system, batch id); '
             + CAST(@AnyCnt - @FullCnt AS varchar(20)) + ' expose only some; '
             + CAST(@TotalTables - @AnyCnt AS varchar(20)) + ' expose none. Missing by element - load date: '
             + CAST(@MissLoad AS varchar(20)) + ', source system: ' + CAST(@MissSource AS varchar(20))
             + ', batch id: ' + CAST(@MissBatch AS varchar(20)) + '. Lowest-coverage databases: ' + @WorstDbs + '.'
    END
    + CASE WHEN @SkipCount > 0
           THEN ' ' + CAST(@SkipCount AS varchar(20)) + ' database(s) could not be read and were excluded from the assessment.'
           ELSE '' END;

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;

IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID('tempdb..#Col') IS NOT NULL DROP TABLE #Col;
IF OBJECT_ID('tempdb..#Tbl') IS NOT NULL DROP TABLE #Tbl;
IF OBJECT_ID('tempdb..#Flag') IS NOT NULL DROP TABLE #Flag;
IF OBJECT_ID('tempdb..#Skipped') IS NOT NULL DROP TABLE #Skipped;