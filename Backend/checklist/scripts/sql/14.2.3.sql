SET NOCOUNT ON;

DECLARE @IsAzureSqlDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @UptimeDays int = 0;

BEGIN TRY
    SELECT @UptimeDays = DATEDIFF(DAY, si.sqlserver_start_time, GETDATE())
    FROM sys.dm_os_sys_info si;
END TRY
BEGIN CATCH
    SET @UptimeDays = 0;
END CATCH

SET @UptimeDays = ISNULL(@UptimeDays, 0);

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
CREATE TABLE #Findings
(
    DatabaseName sysname       NOT NULL,
    SchemaName   sysname       NOT NULL,
    TableName    sysname       NOT NULL,
    IndexName    sysname       NOT NULL,
    IssueType    varchar(20)   NOT NULL,
    Detail       nvarchar(400) NULL
);

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
CREATE TABLE #Dbs (DatabaseName sysname NOT NULL);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #Dbs (DatabaseName) SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.is_read_only = 0
      AND d.user_access = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db sysname, @prefix nvarchar(300), @sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Dbs ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

    SET @sql = N'
    WITH IdxBase AS
    (
        SELECT i.object_id,
               i.index_id,
               i.name        AS IndexName,
               i.is_unique   AS IsUnique,
               ISNULL(i.filter_definition, N'''') AS FilterDef,
               s.name        AS SchemaName,
               o.name        AS TableName
        FROM ' + @prefix + N'sys.indexes i
        INNER JOIN ' + @prefix + N'sys.objects o ON o.object_id = i.object_id
        INNER JOIN ' + @prefix + N'sys.schemas s ON s.schema_id = o.schema_id
        WHERE o.type = ''U''
          AND o.is_ms_shipped = 0
          AND i.type_desc = ''NONCLUSTERED''
          AND i.is_primary_key = 0
          AND i.is_unique_constraint = 0
          AND i.is_hypothetical = 0
          AND i.name IS NOT NULL
    ),
    IdxKeys AS
    (
        SELECT b.object_id, b.index_id, b.IndexName, b.IsUnique, b.FilterDef,
               b.SchemaName, b.TableName,
               KeyCols = ISNULL(STUFF((
                   SELECT N'','' + CAST(ic.column_id AS nvarchar(12))
                          + CASE WHEN ic.is_descending_key = 1 THEN N''D'' ELSE N''A'' END
                   FROM ' + @prefix + N'sys.index_columns ic
                   WHERE ic.object_id = b.object_id
                     AND ic.index_id  = b.index_id
                     AND ic.is_included_column = 0
                   ORDER BY ic.key_ordinal
                   FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 1, N''''), N''''),
               InclCols = ISNULL(STUFF((
                   SELECT N'','' + CAST(ic.column_id AS nvarchar(12))
                   FROM ' + @prefix + N'sys.index_columns ic
                   WHERE ic.object_id = b.object_id
                     AND ic.index_id  = b.index_id
                     AND ic.is_included_column = 1
                   ORDER BY ic.column_id
                   FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 1, N''''), N'''')
        FROM IdxBase b
    ),
    Unused AS
    (
        SELECT k.SchemaName, k.TableName, k.IndexName,
               ISNULL(us.user_updates, 0) AS Updates
        FROM IdxKeys k
        LEFT JOIN sys.dm_db_index_usage_stats us
               ON us.database_id = DB_ID(@dbname)
              AND us.object_id   = k.object_id
              AND us.index_id    = k.index_id
        WHERE ISNULL(us.user_seeks, 0)   = 0
          AND ISNULL(us.user_scans, 0)   = 0
          AND ISNULL(us.user_lookups, 0) = 0
          AND ISNULL(us.user_updates, 0) > 0
    ),
    Dups AS
    (
        SELECT k.SchemaName, k.TableName, k.IndexName,
               ROW_NUMBER() OVER (PARTITION BY k.object_id, k.KeyCols, k.InclCols, k.IsUnique, k.FilterDef
                                  ORDER BY k.index_id) AS rn,
               COUNT(*)     OVER (PARTITION BY k.object_id, k.KeyCols, k.InclCols, k.IsUnique, k.FilterDef) AS cnt
        FROM IdxKeys k
    )
    INSERT INTO #Findings (DatabaseName, SchemaName, TableName, IndexName, IssueType, Detail)
    SELECT @dbname, u.SchemaName, u.TableName, u.IndexName, ''Unused'',
           N''no reads since counters reset; writes maintained = '' + CAST(u.Updates AS nvarchar(20))
    FROM Unused u
    UNION ALL
    SELECT @dbname, d.SchemaName, d.TableName, d.IndexName, ''Duplicate'',
           N''shares an identical key/include signature with '' + CAST(d.cnt - 1 AS nvarchar(10)) + N'' other index(es)''
    FROM Dups d
    WHERE d.cnt > 1 AND d.rn > 1;';

    BEGIN TRY
        EXEC sp_executesql @sql, N'@dbname sysname', @dbname = @db;
    END TRY
    BEGIN CATCH
        SET @prefix = @prefix; -- database became unreadable mid-scan; skip it
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @UnusedCount int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = 'Unused');
DECLARE @DupCount    int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = 'Duplicate');
DECLARE @Total       int = 0;
DECLARE @DbCount     int = (SELECT COUNT(*) FROM #Dbs);

SET @Total = @UnusedCount + @DupCount;

DECLARE @DbList nvarchar(max) = ISNULL(STUFF((
    SELECT N', ' + d.DatabaseName
    FROM #Dbs d
    ORDER BY d.DatabaseName
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @Sample nvarchar(max) = ISNULL(STUFF((
    SELECT TOP (10) N'; ' + f.DatabaseName + N'.' + f.SchemaName + N'.' + f.TableName
                    + N'.' + f.IndexName + N' [' + f.IssueType + N': ' + ISNULL(f.Detail, N'') + N']'
    FROM #Findings f
    ORDER BY f.IssueType, f.DatabaseName, f.SchemaName, f.TableName, f.IndexName
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'');

DECLARE @Result varchar(20);
DECLARE @Score  int;
DECLARE @Finding nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No accessible, online, read-write user database was found on this instance, so unused and duplicate indexes could not be assessed and the control cannot be evidenced. Re-run with an account holding VIEW DEFINITION and VIEW SERVER STATE (or VIEW DATABASE STATE on Azure SQL Database).';
END
ELSE IF @Total = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Scanned ' + CAST(@DbCount AS nvarchar(10)) + N' user database(s) and found no unused nonclustered indexes (zero seeks, scans and lookups with non-zero updates) and no duplicate nonclustered indexes (identical key order/direction, included columns, uniqueness and filter). SQL Server uptime at time of check: '
                 + CAST(@UptimeDays AS nvarchar(10)) + N' day(s). Databases scanned: ' + @DbList + N'.';
END
ELSE IF @DupCount = 0 AND @UptimeDays < 30
BEGIN
    SET @Score = 2;
    SET @Finding = N'Found ' + CAST(@UnusedCount AS nvarchar(10)) + N' apparently unused nonclustered index(es) across ' + CAST(@DbCount AS nvarchar(10))
                 + N' user database(s) and no duplicate indexes, but SQL Server uptime is only ' + CAST(@UptimeDays AS nvarchar(10))
                 + N' day(s). sys.dm_db_index_usage_stats counters reset on instance restart, so this observation window is too short to confirm the indexes are genuinely unused; manual confirmation over a full business cycle is required. Candidates: '
                 + @Sample + CASE WHEN @UnusedCount > 10 THEN N' ... (showing first 10 of ' + CAST(@UnusedCount AS nvarchar(10)) + N')' ELSE N'' END
                 + N'. Databases scanned: ' + @DbList + N'.';
END
ELSE IF @Total <= 5
BEGIN
    SET @Score = 2;
    SET @Finding = N'Found ' + CAST(@Total AS nvarchar(10)) + N' index issue(s) across ' + CAST(@DbCount AS nvarchar(10)) + N' user database(s): '
                 + CAST(@UnusedCount AS nvarchar(10)) + N' unused and ' + CAST(@DupCount AS nvarchar(10))
                 + N' duplicate nonclustered index(es). Index cleanup is largely in place but not complete. SQL Server uptime: '
                 + CAST(@UptimeDays AS nvarchar(10)) + N' day(s). Details: ' + @Sample + N'. Databases scanned: ' + @DbList + N'.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'Found ' + CAST(@Total AS nvarchar(10)) + N' index issue(s) across ' + CAST(@DbCount AS nvarchar(10)) + N' user database(s): '
                 + CAST(@UnusedCount AS nvarchar(10)) + N' unused and ' + CAST(@DupCount AS nvarchar(10))
                 + N' duplicate nonclustered index(es). Unused and duplicate indexes have not been removed. SQL Server uptime: '
                 + CAST(@UptimeDays AS nvarchar(10)) + N' day(s). First 10: ' + @Sample
                 + N'. Databases scanned: ' + @DbList + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result  AS Result,
       @Score   AS Score,
       @DbList  AS DatabaseQueried,
       @Finding AS Finding;

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;