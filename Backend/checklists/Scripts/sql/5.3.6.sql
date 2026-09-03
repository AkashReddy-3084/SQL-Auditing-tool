SET NOCOUNT ON;

DECLARE @Result varchar(20) = 'Fail';
DECLARE @Score int = 0;
DECLARE @DatabaseQueried nvarchar(max) = N'None';
DECLARE @Finding nvarchar(max) = N'No database found to be queried';

IF OBJECT_ID('tempdb..#db_list') IS NOT NULL DROP TABLE #db_list;
IF OBJECT_ID('tempdb..#db_findings') IS NOT NULL DROP TABLE #db_findings;
IF OBJECT_ID('tempdb..#tmp_one') IS NOT NULL DROP TABLE #tmp_one;

CREATE TABLE #db_list
(
    DatabaseName sysname NOT NULL PRIMARY KEY
);

CREATE TABLE #db_findings
(
    DatabaseName sysname NOT NULL,
    DimTableCount int NOT NULL DEFAULT 0,
    UnknownMemberHits bigint NOT NULL DEFAULT 0,
    FactUnknownHits bigint NOT NULL DEFAULT 0,
    MonitorObjectCount int NOT NULL DEFAULT 0
);

CREATE TABLE #tmp_one
(
    DimTableCount int NOT NULL,
    UnknownMemberHits bigint NOT NULL,
    FactUnknownHits bigint NOT NULL,
    MonitorObjectCount int NOT NULL
);

INSERT INTO #db_list (DatabaseName)
SELECT d.name
FROM sys.databases d
WHERE d.state = 0
  AND d.database_id > 4
  AND HAS_DBACCESS(d.name) = 1
  AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb', N'distribution')
  AND d.name NOT LIKE N'%ReportServer%';

IF NOT EXISTS (SELECT 1 FROM #db_list)
BEGIN
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END;

DECLARE @IsAzure bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;
DECLARE @DatabaseName sysname;
DECLARE @DbNameLiteral nvarchar(260);
DECLARE @Sql nvarchar(max);
DECLARE @JobMonitorCount int = 0;
DECLARE @DimTableCount int;
DECLARE @UnknownMemberHits bigint;
DECLARE @FactUnknownHits bigint;
DECLARE @MonitorObjectCount int;

BEGIN TRY
    IF DB_ID(N'msdb') IS NOT NULL AND @IsAzure = 0
    BEGIN
        SELECT @JobMonitorCount = COUNT(*)
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobsteps js
            ON js.job_id = j.job_id
        WHERE j.enabled = 1
          AND (
                js.command LIKE N'%unknown%member%'
             OR js.command LIKE N'%default member%'
             OR js.command LIKE N'%unknown dimension%'
             OR js.command LIKE N'%late arriving%'
             OR js.command LIKE N'%late-arriving%'
          );
    END
END TRY
BEGIN CATCH
    SET @JobMonitorCount = 0;
END CATCH;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT DatabaseName
FROM #db_list
ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DatabaseName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @DimTableCount = 0;
    SET @UnknownMemberHits = 0;
    SET @FactUnknownHits = 0;
    SET @MonitorObjectCount = 0;
    DELETE FROM #tmp_one;

    SET @DbNameLiteral = REPLACE(@DatabaseName, '''', '''''');

    IF @IsAzure = 1
    BEGIN
        SET @Sql = N'
DECLARE @dimCount int = 0;
DECLARE @unknownHits bigint = 0;
DECLARE @factHits bigint = 0;
DECLARE @monitorCount int = 0;
DECLARE @stmt nvarchar(max);

SELECT @dimCount = COUNT(*)
FROM ' + QUOTENAME(@DatabaseName) + N'.sys.tables t
INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.schemas s
    ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND (t.name LIKE N''dim%'' OR t.name LIKE N''%dimension%'');

SELECT @monitorCount = COUNT(*)
FROM ' + QUOTENAME(@DatabaseName) + N'.sys.objects o
WHERE o.is_ms_shipped = 0
  AND o.type IN (''P'',''V'',''U'',''FN'',''IF'',''TF'')
  AND (
        o.name LIKE N''%unknown%member%''
     OR o.name LIKE N''%default%member%''
     OR o.name LIKE N''%unknown%dim%''
     OR o.name LIKE N''%dq%unknown%''
     OR o.name LIKE N''%monitor%unknown%''
     OR o.name LIKE N''%late%arriving%''
     OR o.name LIKE N''%unk%member%''
     OR o.name LIKE N''%orphan%member%''
  );

DECLARE col_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    CASE
        WHEN ty.name IN (N''tinyint'', N''smallint'', N''int'', N''bigint'', N''decimal'', N''numeric'')
            THEN N''SELECT @o = ISNULL(@o,0) + CONVERT(bigint, COUNT_BIG(*)) FROM ''
                + QUOTENAME(N''' + @DbNameLiteral + N''') + N''.'' + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name)
                + N'' WHERE '' + QUOTENAME(c.name) + N'' IN (-1, 0)''
        WHEN ty.name IN (N''varchar'', N''nvarchar'', N''char'', N''nchar'')
            THEN N''SELECT @o = ISNULL(@o,0) + CONVERT(bigint, COUNT_BIG(*)) FROM ''
                + QUOTENAME(N''' + @DbNameLiteral + N''') + N''.'' + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name)
                + N'' WHERE UPPER(LTRIM(RTRIM(CONVERT(nvarchar(400), '' + QUOTENAME(c.name) + N'')))) IN (''
                + N''N''''UNKNOWN'''', N''''N/A'''', N''''NA'''', N''''NONE'''', N''''DEFAULT'''', N''''NOT APPLICABLE'''', N''''UNK'''', N''''TBD'''', N'''''''''')''
                + N'' OR LTRIM(RTRIM(CONVERT(nvarchar(400), '' + QUOTENAME(c.name) + N''))) IN (N''''-1'''', N''''0'''')''
        ELSE NULL
    END
FROM ' + QUOTENAME(@DatabaseName) + N'.sys.tables t
INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.schemas s ON s.schema_id = t.schema_id
INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.columns c ON c.object_id = t.object_id
INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
  AND (t.name LIKE N''dim%'' OR t.name LIKE N''%dimension%'')
  AND (
        c.name LIKE N''%key%'' OR c.name LIKE N''%id'' OR c.name LIKE N''%code%''
     OR c.name LIKE N''%name%'' OR c.name LIKE N''%member%'' OR c.name LIKE N''%sk'' OR c.name LIKE N''%bk%''
  );

OPEN col_cursor;
FETCH NEXT FROM col_cursor INTO @stmt;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @stmt IS NOT NULL
    BEGIN
        BEGIN TRY
            EXEC sp_executesql @stmt, N''@o bigint OUTPUT'', @o = @unknownHits OUTPUT;
        END TRY
        BEGIN CATCH
        END CATCH
    END
    FETCH NEXT FROM col_cursor INTO @stmt;
END
CLOSE col_cursor;
DEALLOCATE col_cursor;

DECLARE fact_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT TOP (40)
    N''SELECT @o = ISNULL(@o,0) + CONVERT(bigint, COUNT_BIG(*)) FROM ''
    + QUOTENAME(N''' + @DbNameLiteral + N''') + N''.'' + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name)
    + N'' WHERE '' + QUOTENAME(c.name) + N'' IN (-1, 0)''
FROM ' + QUOTENAME(@DatabaseName) + N'.sys.tables t
INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.schemas s ON s.schema_id = t.schema_id
INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.columns c ON c.object_id = t.object_id
INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
  AND (t.name LIKE N''fact%'' OR t.name LIKE N''fct%'')
  AND ty.name IN (N''tinyint'', N''smallint'', N''int'', N''bigint'')
  AND (c.name LIKE N''%key%'' OR c.name LIKE N''%id'' OR c.name LIKE N''%sk'');

OPEN fact_cursor;
FETCH NEXT FROM fact_cursor INTO @stmt;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC sp_executesql @stmt, N''@o bigint OUTPUT'', @o = @factHits OUTPUT;
    END TRY
    BEGIN CATCH
    END CATCH
    FETCH NEXT FROM fact_cursor INTO @stmt;
END
CLOSE fact_cursor;
DEALLOCATE fact_cursor;

SELECT
    ISNULL(@dimCount, 0) AS DimTableCount,
    ISNULL(@unknownHits, 0) AS UnknownMemberHits,
    ISNULL(@factHits, 0) AS FactUnknownHits,
    ISNULL(@monitorCount, 0) AS MonitorObjectCount;
';
    END
    ELSE
    BEGIN
        SET @Sql = N'
USE ' + QUOTENAME(@DatabaseName) + N';
DECLARE @dimCount int = 0;
DECLARE @unknownHits bigint = 0;
DECLARE @factHits bigint = 0;
DECLARE @monitorCount int = 0;
DECLARE @stmt nvarchar(max);

SELECT @dimCount = COUNT(*)
FROM sys.tables t
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND (t.name LIKE N''dim%'' OR t.name LIKE N''%dimension%'');

SELECT @monitorCount = COUNT(*)
FROM sys.objects o
WHERE o.is_ms_shipped = 0
  AND o.type IN (''P'',''V'',''U'',''FN'',''IF'',''TF'')
  AND (
        o.name LIKE N''%unknown%member%''
     OR o.name LIKE N''%default%member%''
     OR o.name LIKE N''%unknown%dim%''
     OR o.name LIKE N''%dq%unknown%''
     OR o.name LIKE N''%monitor%unknown%''
     OR o.name LIKE N''%late%arriving%''
     OR o.name LIKE N''%unk%member%''
     OR o.name LIKE N''%orphan%member%''
  );

DECLARE col_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    CASE
        WHEN ty.name IN (N''tinyint'', N''smallint'', N''int'', N''bigint'', N''decimal'', N''numeric'')
            THEN N''SELECT @o = ISNULL(@o,0) + CONVERT(bigint, COUNT_BIG(*)) FROM ''
                + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name)
                + N'' WHERE '' + QUOTENAME(c.name) + N'' IN (-1, 0)''
        WHEN ty.name IN (N''varchar'', N''nvarchar'', N''char'', N''nchar'')
            THEN N''SELECT @o = ISNULL(@o,0) + CONVERT(bigint, COUNT_BIG(*)) FROM ''
                + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name)
                + N'' WHERE UPPER(LTRIM(RTRIM(CONVERT(nvarchar(400), '' + QUOTENAME(c.name) + N'')))) IN (''
                + N''N''''UNKNOWN'''', N''''N/A'''', N''''NA'''', N''''NONE'''', N''''DEFAULT'''', N''''NOT APPLICABLE'''', N''''UNK'''', N''''TBD'''', N'''''''''')''
                + N'' OR LTRIM(RTRIM(CONVERT(nvarchar(400), '' + QUOTENAME(c.name) + N''))) IN (N''''-1'''', N''''0'''')''
        ELSE NULL
    END
FROM sys.tables t
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
INNER JOIN sys.columns c ON c.object_id = t.object_id
INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
  AND (t.name LIKE N''dim%'' OR t.name LIKE N''%dimension%'')
  AND (
        c.name LIKE N''%key%'' OR c.name LIKE N''%id'' OR c.name LIKE N''%code%''
     OR c.name LIKE N''%name%'' OR c.name LIKE N''%member%'' OR c.name LIKE N''%sk'' OR c.name LIKE N''%bk%''
  );

OPEN col_cursor;
FETCH NEXT FROM col_cursor INTO @stmt;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @stmt IS NOT NULL
    BEGIN
        BEGIN TRY
            EXEC sp_executesql @stmt, N''@o bigint OUTPUT'', @o = @unknownHits OUTPUT;
        END TRY
        BEGIN CATCH
        END CATCH
    END
    FETCH NEXT FROM col_cursor INTO @stmt;
END
CLOSE col_cursor;
DEALLOCATE col_cursor;

DECLARE fact_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT TOP (40)
    N''SELECT @o = ISNULL(@o,0) + CONVERT(bigint, COUNT_BIG(*)) FROM ''
    + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name)
    + N'' WHERE '' + QUOTENAME(c.name) + N'' IN (-1, 0)''
FROM sys.tables t
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
INNER JOIN sys.columns c ON c.object_id = t.object_id
INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
  AND (t.name LIKE N''fact%'' OR t.name LIKE N''fct%'')
  AND ty.name IN (N''tinyint'', N''smallint'', N''int'', N''bigint'')
  AND (c.name LIKE N''%key%'' OR c.name LIKE N''%id'' OR c.name LIKE N''%sk'');

OPEN fact_cursor;
FETCH NEXT FROM fact_cursor INTO @stmt;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC sp_executesql @stmt, N''@o bigint OUTPUT'', @o = @factHits OUTPUT;
    END TRY
    BEGIN CATCH
    END CATCH
    FETCH NEXT FROM fact_cursor INTO @stmt;
END
CLOSE fact_cursor;
DEALLOCATE fact_cursor;

SELECT
    ISNULL(@dimCount, 0) AS DimTableCount,
    ISNULL(@unknownHits, 0) AS UnknownMemberHits,
    ISNULL(@factHits, 0) AS FactUnknownHits,
    ISNULL(@monitorCount, 0) AS MonitorObjectCount;
';
    END

    BEGIN TRY
        INSERT INTO #tmp_one (DimTableCount, UnknownMemberHits, FactUnknownHits, MonitorObjectCount)
        EXEC sp_executesql @Sql;

        SELECT
            @DimTableCount = DimTableCount,
            @UnknownMemberHits = UnknownMemberHits,
            @FactUnknownHits = FactUnknownHits,
            @MonitorObjectCount = MonitorObjectCount
        FROM #tmp_one;
    END TRY
    BEGIN CATCH
        SET @DimTableCount = 0;
        SET @UnknownMemberHits = 0;
        SET @FactUnknownHits = 0;
        SET @MonitorObjectCount = 0;
    END CATCH;

    INSERT INTO #db_findings
    (
        DatabaseName,
        DimTableCount,
        UnknownMemberHits,
        FactUnknownHits,
        MonitorObjectCount
    )
    VALUES
    (
        @DatabaseName,
        ISNULL(@DimTableCount, 0),
        ISNULL(@UnknownMemberHits, 0),
        ISNULL(@FactUnknownHits, 0),
        ISNULL(@MonitorObjectCount, 0)
    );

    FETCH NEXT FROM db_cursor INTO @DatabaseName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @dbCount int = (SELECT COUNT(*) FROM #db_findings);
DECLARE @dimDbs int = (SELECT COUNT(*) FROM #db_findings WHERE DimTableCount > 0);
DECLARE @totalDims int = (SELECT ISNULL(SUM(DimTableCount), 0) FROM #db_findings);
DECLARE @totalUnknown bigint = (SELECT ISNULL(SUM(UnknownMemberHits), 0) FROM #db_findings);
DECLARE @totalFactUnknown bigint = (SELECT ISNULL(SUM(FactUnknownHits), 0) FROM #db_findings);
DECLARE @totalMonitors int = (SELECT ISNULL(SUM(MonitorObjectCount), 0) FROM #db_findings) + CASE WHEN @JobMonitorCount > 0 THEN 1 ELSE 0 END;
DECLARE @dbsWithMonitor int = (SELECT COUNT(*) FROM #db_findings WHERE MonitorObjectCount > 0);
DECLARE @dbsWithFactUnknown int = (SELECT COUNT(*) FROM #db_findings WHERE FactUnknownHits > 0);

SET @DatabaseQueried = STUFF((
    SELECT N', ' + f.DatabaseName
    FROM #db_findings f
    ORDER BY f.DatabaseName
    FOR XML PATH(N''), TYPE
).value(N'.', N'nvarchar(max)'), 1, 2, N'');

IF @DatabaseQueried IS NULL OR LTRIM(RTRIM(@DatabaseQueried)) = N''
BEGIN
    SET @DatabaseQueried = N'None';
END

IF @dbCount = 0 OR @DatabaseQueried = N'None'
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
END
ELSE IF @totalDims = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'Queried ' + CONVERT(nvarchar(10), @dbCount)
        + N' database(s); no dimension-like tables (dim*/%dimension%) were found, so unknown/default member usage monitoring could not be assessed';
END
ELSE IF @totalMonitors > 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Found ' + CONVERT(nvarchar(10), @totalDims)
        + N' dimension-like table(s) across ' + CONVERT(nvarchar(10), @dimDbs)
        + N' database(s). Monitoring evidence present: '
        + CONVERT(nvarchar(10), @totalMonitors)
        + N' object/job signal(s)'
        + CASE WHEN @dbsWithMonitor > 0 THEN N' in ' + CONVERT(nvarchar(10), @dbsWithMonitor) + N' database(s)' ELSE N'' END
        + N'. Unknown/default member row hits=' + CONVERT(nvarchar(20), @totalUnknown)
        + N'; fact-side unknown key hits=' + CONVERT(nvarchar(20), @totalFactUnknown)
        + N'. Unknown/default dimension member usage appears monitored';
END
ELSE IF @totalUnknown > 0 AND @totalFactUnknown = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Found ' + CONVERT(nvarchar(10), @totalDims)
        + N' dimension-like table(s) with unknown/default member values present ('
        + CONVERT(nvarchar(20), @totalUnknown)
        + N' row hits) and no material fact-side unknown key usage ('
        + CONVERT(nvarchar(20), @totalFactUnknown)
        + N'). Default members appear controlled';
END
ELSE IF @totalUnknown > 0 AND @totalFactUnknown > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Found unknown/default member row hits ('
        + CONVERT(nvarchar(20), @totalUnknown)
        + N') and fact-side unknown key usage ('
        + CONVERT(nvarchar(20), @totalFactUnknown)
        + N') across ' + CONVERT(nvarchar(10), @dbsWithFactUnknown)
        + N' database(s), but no monitoring objects/jobs for unknown/default member usage were detected';
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = N'Found ' + CONVERT(nvarchar(10), @totalDims)
        + N' dimension-like table(s) in ' + CONVERT(nvarchar(10), @dimDbs)
        + N' database(s), but no explicit unknown/default member monitoring artifacts and limited unknown-member evidence (unknown hits='
        + CONVERT(nvarchar(20), @totalUnknown)
        + N', fact unknown hits=' + CONVERT(nvarchar(20), @totalFactUnknown)
        + N'). Monitoring coverage appears incomplete';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;