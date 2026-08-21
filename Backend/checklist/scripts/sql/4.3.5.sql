SET NOCOUNT ON;

DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(4000) = N'';
DECLARE @Finding NVARCHAR(4000);
DECLARE @UptimeDays INT = NULL;
DECLARE @TotalNC INT = 0;
DECLARE @UnusedNC INT = 0;
DECLARE @WriteOnlyNC INT = 0;
DECLARE @UnusedPct DECIMAL(5,1) = 0.0;
DECLARE @Sample NVARCHAR(1000) = N'';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

BEGIN TRY
    SELECT @UptimeDays = DATEDIFF(DAY, si.sqlserver_start_time, GETDATE())
    FROM sys.dm_os_sys_info AS si;
END TRY
BEGIN CATCH
    SET @UptimeDays = NULL;
END CATCH

CREATE TABLE #Databases
(
    DbName    SYSNAME,
    Succeeded BIT NOT NULL DEFAULT (0)
);

CREATE TABLE #IndexUsage
(
    DbName      SYSNAME,
    SchemaName  SYSNAME,
    TableName   SYSNAME,
    IndexName   SYSNAME,
    UserReads   BIGINT,
    UserUpdates BIGINT
);

INSERT INTO #Databases (DbName, Succeeded)
SELECT d.name, 0
FROM sys.databases AS d
WHERE d.database_id > 4
  AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb')
  AND d.state = 0
  AND d.is_read_only = 0
  AND d.user_access = 0
  AND HAS_DBACCESS(d.name) = 1;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DbName FROM #Databases ORDER BY DbName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
INSERT INTO #IndexUsage (DbName, SchemaName, TableName, IndexName, UserReads, UserUpdates)
SELECT
    DB_NAME(),
    s.name,
    o.name,
    i.name,
    ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0),
    ISNULL(us.user_updates, 0)
FROM sys.indexes AS i
INNER JOIN sys.objects AS o
    ON i.object_id = o.object_id
INNER JOIN sys.schemas AS s
    ON o.schema_id = s.schema_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON us.object_id = i.object_id
   AND us.index_id = i.index_id
   AND us.database_id = DB_ID()
WHERE i.type_desc = N''NONCLUSTERED''
  AND i.is_primary_key = 0
  AND i.is_unique_constraint = 0
  AND i.is_hypothetical = 0
  AND i.name IS NOT NULL
  AND o.type = N''U''
  AND o.is_ms_shipped = 0;';

        EXEC sp_executesql @Sql;

        UPDATE #Databases SET Succeeded = 1 WHERE DbName = @DbName;
    END TRY
    BEGIN CATCH
        UPDATE #Databases SET Succeeded = 0 WHERE DbName = @DbName;
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @DatabaseQueried = ISNULL(STUFF((
        SELECT N', ' + d.DbName
        FROM #Databases AS d
        WHERE d.Succeeded = 1
        ORDER BY d.DbName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(4000)'), 1, 2, N''), N'');

SELECT @TotalNC = COUNT(*) FROM #IndexUsage;
SELECT @UnusedNC = COUNT(*) FROM #IndexUsage WHERE UserReads = 0;
SELECT @WriteOnlyNC = COUNT(*) FROM #IndexUsage WHERE UserReads = 0 AND UserUpdates > 0;

IF @TotalNC > 0
    SET @UnusedPct = CAST(@UnusedNC AS DECIMAL(10,2)) * 100.0 / CAST(@TotalNC AS DECIMAL(10,2));

SELECT @Sample = ISNULL(STUFF((
        SELECT TOP (5) N', ' + iu.DbName + N'.' + iu.SchemaName + N'.' + iu.TableName + N'.' + iu.IndexName
        FROM #IndexUsage AS iu
        WHERE iu.UserReads = 0
        ORDER BY iu.UserUpdates DESC, iu.DbName, iu.SchemaName, iu.TableName, iu.IndexName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N''), N'');

DROP TABLE #IndexUsage;
DROP TABLE #Databases;

IF @DatabaseQueried = N''
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END
ELSE IF @TotalNC = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No user-created non-clustered indexes (excluding primary key and unique constraint indexes) exist in the queried database(s) ['
                 + @DatabaseQueried + N'], so there are no unused indexes to remove.';
END
ELSE IF @UnusedNC = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CAST(@TotalNC AS NVARCHAR(20)) + N' user non-clustered indexes across database(s) ['
                 + @DatabaseQueried + N'] show read activity (seeks, scans or lookups) in sys.dm_db_index_usage_stats over '
                 + ISNULL(CAST(@UptimeDays AS NVARCHAR(20)), N'unknown') + N' day(s) of instance uptime. No unused indexes remain.';
END
ELSE IF @UptimeDays IS NOT NULL AND @UptimeDays < 7
BEGIN
    SET @Score = 1;
    SET @Finding = CAST(@UnusedNC AS NVARCHAR(20)) + N' of ' + CAST(@TotalNC AS NVARCHAR(20))
                 + N' user non-clustered indexes across database(s) [' + @DatabaseQueried
                 + N'] show zero reads, but the instance has only been up for ' + CAST(@UptimeDays AS NVARCHAR(20))
                 + N' day(s), so sys.dm_db_index_usage_stats counters are not yet representative. Examples: ' + @Sample
                 + N'. Manual re-check after a full business cycle is required.';
END
ELSE IF @UnusedPct <= 10.0
BEGIN
    SET @Score = 2;
    SET @Finding = CAST(@UnusedNC AS NVARCHAR(20)) + N' of ' + CAST(@TotalNC AS NVARCHAR(20)) + N' user non-clustered indexes ('
                 + CAST(@UnusedPct AS NVARCHAR(10)) + N'%) across database(s) [' + @DatabaseQueried
                 + N'] have zero seeks, scans and lookups over ' + ISNULL(CAST(@UptimeDays AS NVARCHAR(20)), N'unknown')
                 + N' day(s) of uptime; ' + CAST(@WriteOnlyNC AS NVARCHAR(20))
                 + N' of those are still maintained by writes. Examples: ' + @Sample
                 + N'. Index housekeeping is largely in place.';
END
ELSE IF @UnusedPct <= 30.0
BEGIN
    SET @Score = 1;
    SET @Finding = CAST(@UnusedNC AS NVARCHAR(20)) + N' of ' + CAST(@TotalNC AS NVARCHAR(20)) + N' user non-clustered indexes ('
                 + CAST(@UnusedPct AS NVARCHAR(10)) + N'%) across database(s) [' + @DatabaseQueried
                 + N'] have zero seeks, scans and lookups over ' + ISNULL(CAST(@UptimeDays AS NVARCHAR(20)), N'unknown')
                 + N' day(s) of uptime; ' + CAST(@WriteOnlyNC AS NVARCHAR(20))
                 + N' of those still incur write maintenance. Examples: ' + @Sample
                 + N'. Unused indexes have not been consistently identified and removed.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = CAST(@UnusedNC AS NVARCHAR(20)) + N' of ' + CAST(@TotalNC AS NVARCHAR(20)) + N' user non-clustered indexes ('
                 + CAST(@UnusedPct AS NVARCHAR(10)) + N'%) across database(s) [' + @DatabaseQueried
                 + N'] have zero seeks, scans and lookups over ' + ISNULL(CAST(@UptimeDays AS NVARCHAR(20)), N'unknown')
                 + N' day(s) of uptime; ' + CAST(@WriteOnlyNC AS NVARCHAR(20))
                 + N' of those are pure write overhead. Examples: ' + @Sample
                 + N'. There is no evidence of any unused-index identification or removal process.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;