SET NOCOUNT ON;

-- Read-only assessment: are nonclustered indexes justified by observed workload usage?

DECLARE @IsAzureSqlDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#ScannedDb') IS NOT NULL DROP TABLE #ScannedDb;
CREATE TABLE #ScannedDb
(
    DatabaseName sysname NOT NULL
);

IF OBJECT_ID('tempdb..#IndexAlignment') IS NOT NULL DROP TABLE #IndexAlignment;
CREATE TABLE #IndexAlignment
(
    DatabaseName sysname NOT NULL,
    SchemaName   sysname NOT NULL,
    TableName    sysname NOT NULL,
    IndexName    sysname NULL,
    UserSeeks    bigint  NOT NULL,
    UserScans    bigint  NOT NULL,
    UserLookups  bigint  NOT NULL,
    UserUpdates  bigint  NOT NULL,
    IsUnused     bit     NOT NULL,
    IsDuplicate  bit     NOT NULL
);

DECLARE @Db     sysname;
DECLARE @Prefix nvarchar(300);
DECLARE @Sql    nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
    FROM sys.databases AS d
    WHERE (@IsAzureSqlDb = 1 AND d.database_id = DB_ID())
       OR (@IsAzureSqlDb = 0
           AND d.database_id > 4
           AND d.name NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution', 'SSISDB', 'ReportServer', 'ReportServerTempDB')
           AND d.state_desc = 'ONLINE'
           AND d.source_database_id IS NULL
           AND d.is_in_standby = 0
           AND HAS_DBACCESS(d.name) = 1)
    ORDER BY d.name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@Db) + N'.' END;

        SET @Sql = N'
WITH IndexKeys AS
(
    SELECT  i.object_id,
            i.index_id,
            KeyList = STUFF((SELECT '','' + CAST(ic.column_id AS varchar(10))
                                    + CASE WHEN ic.is_descending_key = 1 THEN ''D'' ELSE ''A'' END
                             FROM ' + @Prefix + N'sys.index_columns AS ic
                             WHERE ic.object_id = i.object_id
                               AND ic.index_id  = i.index_id
                               AND ic.is_included_column = 0
                             ORDER BY ic.key_ordinal
                             FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 1, '''')
    FROM ' + @Prefix + N'sys.indexes AS i
    INNER JOIN ' + @Prefix + N'sys.tables AS t ON t.object_id = i.object_id
    WHERE i.type_desc = ''NONCLUSTERED''
      AND i.is_primary_key = 0
      AND i.is_unique_constraint = 0
      AND i.is_hypothetical = 0
      AND t.is_ms_shipped = 0
),
DupKeys AS
(
    SELECT object_id, KeyList, DupCount = COUNT(*)
    FROM IndexKeys
    GROUP BY object_id, KeyList
)
SELECT  @DbNameIn,
        s.name,
        t.name,
        i.name,
        ISNULL(us.user_seeks,   0),
        ISNULL(us.user_scans,   0),
        ISNULL(us.user_lookups, 0),
        ISNULL(us.user_updates, 0),
        CASE WHEN ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) = 0
             THEN 1 ELSE 0 END,
        CASE WHEN dk.DupCount > 1 THEN 1 ELSE 0 END
FROM ' + @Prefix + N'sys.indexes AS i
INNER JOIN ' + @Prefix + N'sys.tables AS t
        ON t.object_id = i.object_id
INNER JOIN ' + @Prefix + N'sys.schemas AS s
        ON s.schema_id = t.schema_id
INNER JOIN IndexKeys AS ik
        ON ik.object_id = i.object_id
       AND ik.index_id  = i.index_id
LEFT JOIN DupKeys AS dk
        ON dk.object_id = ik.object_id
       AND dk.KeyList   = ik.KeyList
LEFT JOIN sys.dm_db_index_usage_stats AS us
        ON us.database_id = DB_ID(@DbNameIn)
       AND us.object_id   = i.object_id
       AND us.index_id    = i.index_id
WHERE i.type_desc = ''NONCLUSTERED''
  AND i.is_primary_key = 0
  AND i.is_unique_constraint = 0
  AND i.is_hypothetical = 0
  AND t.is_ms_shipped = 0;';

        INSERT INTO #IndexAlignment
            (DatabaseName, SchemaName, TableName, IndexName,
             UserSeeks, UserScans, UserLookups, UserUpdates, IsUnused, IsDuplicate)
        EXEC sp_executesql @Sql, N'@DbNameIn sysname', @DbNameIn = @Db;

        INSERT INTO #ScannedDb (DatabaseName) VALUES (@Db);
    END TRY
    BEGIN CATCH
        -- Database unreadable (offline, AG secondary, insufficient permission): skip it.
        SET @Sql = NULL;
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @Db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @UptimeDays int = 0;
BEGIN TRY
    SELECT @UptimeDays = DATEDIFF(day, si.sqlserver_start_time, SYSDATETIME())
    FROM sys.dm_os_sys_info AS si;
END TRY
BEGIN CATCH
    SET @UptimeDays = 0;
END CATCH;

DECLARE @DbCount   int,
        @Total     int,
        @Unused    int,
        @Duplicate int,
        @Problem   int;

SELECT @DbCount = COUNT(*) FROM #ScannedDb;

SELECT  @Total     = COUNT(*),
        @Unused    = SUM(CASE WHEN IsUnused = 1 THEN 1 ELSE 0 END),
        @Duplicate = SUM(CASE WHEN IsDuplicate = 1 THEN 1 ELSE 0 END),
        @Problem   = SUM(CASE WHEN IsUnused = 1 OR IsDuplicate = 1 THEN 1 ELSE 0 END)
FROM #IndexAlignment;

SET @DbCount   = ISNULL(@DbCount, 0);
SET @Total     = ISNULL(@Total, 0);
SET @Unused    = ISNULL(@Unused, 0);
SET @Duplicate = ISNULL(@Duplicate, 0);
SET @Problem   = ISNULL(@Problem, 0);

DECLARE @DbList nvarchar(max) =
    STUFF((SELECT N', ' + sd.DatabaseName
           FROM #ScannedDb AS sd
           ORDER BY sd.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @DbList IS NULL OR LEN(@DbList) = 0
    SET @DbList = N'None';

DECLARE @Examples nvarchar(max) =
    STUFF((SELECT TOP (5) N'; ' + ia.DatabaseName + N'.' + ia.SchemaName + N'.' + ia.TableName
                        + N'.' + ISNULL(ia.IndexName, N'(unnamed)')
                        + N' [reads=' + CAST(ia.UserSeeks + ia.UserScans + ia.UserLookups AS varchar(20))
                        + N', writes=' + CAST(ia.UserUpdates AS varchar(20))
                        + CASE WHEN ia.IsDuplicate = 1 THEN N', duplicate key signature' ELSE N'' END + N']'
           FROM #IndexAlignment AS ia
           WHERE ia.IsUnused = 1 OR ia.IsDuplicate = 1
           ORDER BY ia.UserUpdates DESC, ia.DatabaseName, ia.TableName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @PctProblem decimal(5,1) =
    CASE WHEN @Total > 0 THEN CAST(@Problem * 100.0 / @Total AS decimal(5,1)) ELSE 0.0 END;

DECLARE @Result  nvarchar(50),
        @Score   int,
        @Finding nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'No accessible user databases were found on this instance, so no arbitrary nonclustered indexes could be identified.';
END
ELSE IF @Total = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Scanned ' + CAST(@DbCount AS varchar(10)) + N' user database(s) and found no nonclustered indexes on user tables (excluding primary-key and unique-constraint indexes), so there are no arbitrary nonclustered indexes to report.';
END
ELSE IF @Problem = 0 AND @UptimeDays >= 7
BEGIN
    SET @Score   = 3;
    SET @Finding = N'All ' + CAST(@Total AS varchar(10)) + N' nonclustered index(es) across ' + CAST(@DbCount AS varchar(10))
                 + N' user database(s) have been read by the workload (user_seeks + user_scans + user_lookups > 0) and none duplicate another index''s key-column signature. Usage statistics cover ' + CAST(@UptimeDays AS varchar(10))
                 + N' day(s) of instance uptime, indicating nonclustered indexes align with actual query patterns rather than being arbitrary.';
END
ELSE IF @UptimeDays < 7
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Instance uptime is only ' + CAST(@UptimeDays AS varchar(10))
                 + N' day(s), so sys.dm_db_index_usage_stats has not accumulated a representative workload sample. Of ' + CAST(@Total AS varchar(10))
                 + N' nonclustered index(es) across ' + CAST(@DbCount AS varchar(10)) + N' user database(s), ' + CAST(@Unused AS varchar(10))
                 + N' show no reads and ' + CAST(@Duplicate AS varchar(10)) + N' duplicate another index''s key-column signature ('
                 + CAST(@PctProblem AS varchar(10)) + N'% flagged). Examples: ' + ISNULL(@Examples, N'none') + N'.';
END
ELSE IF @PctProblem <= 10.0
BEGIN
    SET @Score   = 2;
    SET @Finding = CAST(@Problem AS varchar(10)) + N' of ' + CAST(@Total AS varchar(10)) + N' nonclustered index(es) ('
                 + CAST(@PctProblem AS varchar(10)) + N'%) across ' + CAST(@DbCount AS varchar(10))
                 + N' user database(s) are not justified by the workload: ' + CAST(@Unused AS varchar(10))
                 + N' have zero reads over ' + CAST(@UptimeDays AS varchar(10)) + N' day(s) of uptime and ' + CAST(@Duplicate AS varchar(10))
                 + N' duplicate another index''s key-column signature. Examples: ' + ISNULL(@Examples, N'none')
                 + N'. Most indexes align with query patterns, but a small residue appears arbitrary.';
END
ELSE
BEGIN
    SET @Score   = 1;
    SET @Finding = CAST(@Problem AS varchar(10)) + N' of ' + CAST(@Total AS varchar(10)) + N' nonclustered index(es) ('
                 + CAST(@PctProblem AS varchar(10)) + N'%) across ' + CAST(@DbCount AS varchar(10))
                 + N' user database(s) do not align with the observed workload: ' + CAST(@Unused AS varchar(10))
                 + N' have never been read (zero seeks, scans and lookups over ' + CAST(@UptimeDays AS varchar(10))
                 + N' day(s) of uptime) while still incurring maintenance writes, and ' + CAST(@Duplicate AS varchar(10))
                 + N' duplicate another index''s key-column signature. Examples: ' + ISNULL(@Examples, N'none')
                 + N'. This indicates nonclustered indexes were created arbitrarily rather than from query/workload analysis.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @DbList  AS DatabaseQueried,
    @Finding AS Finding;

IF OBJECT_ID('tempdb..#IndexAlignment') IS NOT NULL DROP TABLE #IndexAlignment;
IF OBJECT_ID('tempdb..#ScannedDb') IS NOT NULL DROP TABLE #ScannedDb;