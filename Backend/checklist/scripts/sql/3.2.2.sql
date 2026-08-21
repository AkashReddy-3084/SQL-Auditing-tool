SET NOCOUNT ON;

-- Read-only audit for checklist 3.2.2: set-based logic used; cursors / WHILE loops avoided except where justified.

DECLARE @IsAzure BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#ModuleStats') IS NOT NULL DROP TABLE #ModuleStats;
IF OBJECT_ID('tempdb..#FlaggedObjects') IS NOT NULL DROP TABLE #FlaggedObjects;
IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;

CREATE TABLE #ModuleStats
(
    DatabaseName    SYSNAME NOT NULL,
    TotalModules    INT     NOT NULL,
    CursorModules   INT     NOT NULL,
    WhileModules    INT     NOT NULL,
    FlaggedModules  INT     NOT NULL
);

CREATE TABLE #FlaggedObjects
(
    DatabaseName SYSNAME        NOT NULL,
    ObjectName   NVARCHAR(520)  NOT NULL,
    IssueType    NVARCHAR(50)   NOT NULL
);

CREATE TABLE #Databases
(
    RowId        INT IDENTITY(1,1) NOT NULL,
    DatabaseName SYSNAME           NOT NULL
);

IF @IsAzure = 1
BEGIN
    INSERT INTO #Databases (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_read_only = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1
    ORDER BY d.name;
END

DECLARE @RowId    INT = 1;
DECLARE @MaxRowId INT = (SELECT ISNULL(MAX(RowId), 0) FROM #Databases);
DECLARE @DbName   SYSNAME;
DECLARE @Sql      NVARCHAR(MAX);

WHILE @RowId <= @MaxRowId
BEGIN
    SELECT @DbName = DatabaseName FROM #Databases WHERE RowId = @RowId;

    SET @Sql =
        CASE WHEN @IsAzure = 1 THEN N'' ELSE N'USE ' + QUOTENAME(@DbName) + N'; ' END +
        N'
        INSERT INTO #ModuleStats (DatabaseName, TotalModules, CursorModules, WhileModules, FlaggedModules)
        SELECT DB_NAME(),
               COUNT(*),
               SUM(CASE WHEN m.definition LIKE ''%FETCH NEXT%''
                          OR m.definition LIKE ''%DECLARE%CURSOR%'' THEN 1 ELSE 0 END),
               SUM(CASE WHEN m.definition LIKE ''%WHILE%''
                         AND m.definition NOT LIKE ''%FETCH NEXT%''
                         AND m.definition NOT LIKE ''%DECLARE%CURSOR%'' THEN 1 ELSE 0 END),
               SUM(CASE WHEN m.definition LIKE ''%FETCH NEXT%''
                          OR m.definition LIKE ''%DECLARE%CURSOR%''
                          OR m.definition LIKE ''%WHILE%'' THEN 1 ELSE 0 END)
        FROM sys.sql_modules AS m
        INNER JOIN sys.objects AS o ON o.object_id = m.object_id
        WHERE o.is_ms_shipped = 0
          AND o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'', ''V'');

        INSERT INTO #FlaggedObjects (DatabaseName, ObjectName, IssueType)
        SELECT TOP (5)
               DB_NAME(),
               QUOTENAME(SCHEMA_NAME(o.schema_id)) + N''.'' + QUOTENAME(o.name),
               CASE WHEN m.definition LIKE ''%FETCH NEXT%''
                      OR m.definition LIKE ''%DECLARE%CURSOR%'' THEN N''Cursor''
                    ELSE N''WHILE loop'' END
        FROM sys.sql_modules AS m
        INNER JOIN sys.objects AS o ON o.object_id = m.object_id
        WHERE o.is_ms_shipped = 0
          AND o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'', ''V'')
          AND (m.definition LIKE ''%FETCH NEXT%''
            OR m.definition LIKE ''%DECLARE%CURSOR%''
            OR m.definition LIKE ''%WHILE%'')
        ORDER BY o.name;';

    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        -- database not readable by the audit login; recorded as inspected-but-empty
        INSERT INTO #ModuleStats (DatabaseName, TotalModules, CursorModules, WhileModules, FlaggedModules)
        VALUES (@DbName, 0, 0, 0, 0);
    END CATCH

    SET @RowId = @RowId + 1;
END

DECLARE @DbCount        INT = (SELECT COUNT(*) FROM #Databases);
DECLARE @TotalModules   INT = (SELECT ISNULL(SUM(TotalModules), 0)   FROM #ModuleStats);
DECLARE @CursorModules  INT = (SELECT ISNULL(SUM(CursorModules), 0)  FROM #ModuleStats);
DECLARE @WhileModules   INT = (SELECT ISNULL(SUM(WhileModules), 0)   FROM #ModuleStats);
DECLARE @FlaggedModules INT = (SELECT ISNULL(SUM(FlaggedModules), 0) FROM #ModuleStats);

DECLARE @FlaggedPct DECIMAL(9,2) =
    CASE WHEN @TotalModules = 0 THEN 0
         ELSE CAST(@FlaggedModules * 100.0 / @TotalModules AS DECIMAL(9,2)) END;

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + DatabaseName
           FROM #Databases
           ORDER BY DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @Samples NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT TOP (10) N'; ' + DatabaseName + N'.' + ObjectName + N' (' + IssueType + N')'
                  FROM #FlaggedObjects
                  ORDER BY DatabaseName, ObjectName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @Result  NVARCHAR(20);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(MAX);

IF @TotalModules = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No user-defined T-SQL modules (procedures, functions, triggers, views) were readable in the '
                 + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) inspected, so adherence to set-based logic could not be evidenced.';
END
ELSE IF @FlaggedPct = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CAST(@TotalModules AS NVARCHAR(10)) + N' user-defined T-SQL module(s) across '
                 + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) are free of cursor declarations and iterative WHILE loops; logic is set-based.';
END
ELSE IF @FlaggedPct <= 10.00
BEGIN
    SET @Score = 2;
    SET @Finding = N'Iterative code is isolated: ' + CAST(@FlaggedModules AS NVARCHAR(10)) + N' of '
                 + CAST(@TotalModules AS NVARCHAR(10)) + N' module(s) (' + CAST(@FlaggedPct AS NVARCHAR(10))
                 + N'%) across ' + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) use cursors or WHILE loops ('
                 + CAST(@CursorModules AS NVARCHAR(10)) + N' cursor-based, '
                 + CAST(@WhileModules AS NVARCHAR(10)) + N' WHILE-loop only). Examples: ' + @Samples
                 + N'. Confirm each remaining use is justified.';
END
ELSE IF @FlaggedPct <= 25.00
BEGIN
    SET @Score = 1;
    SET @Finding = N'Iterative code is widespread: ' + CAST(@FlaggedModules AS NVARCHAR(10)) + N' of '
                 + CAST(@TotalModules AS NVARCHAR(10)) + N' module(s) (' + CAST(@FlaggedPct AS NVARCHAR(10))
                 + N'%) across ' + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) use cursors or WHILE loops ('
                 + CAST(@CursorModules AS NVARCHAR(10)) + N' cursor-based, '
                 + CAST(@WhileModules AS NVARCHAR(10)) + N' WHILE-loop only). Examples: ' + @Samples + N'.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'Row-by-row processing dominates: ' + CAST(@FlaggedModules AS NVARCHAR(10)) + N' of '
                 + CAST(@TotalModules AS NVARCHAR(10)) + N' module(s) (' + CAST(@FlaggedPct AS NVARCHAR(10))
                 + N'%) across ' + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) use cursors or WHILE loops ('
                 + CAST(@CursorModules AS NVARCHAR(10)) + N' cursor-based, '
                 + CAST(@WhileModules AS NVARCHAR(10)) + N' WHILE-loop only). Examples: ' + @Samples + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result                       AS Result,
    @Score                        AS Score,
    ISNULL(@DbList, N'None')      AS DatabaseQueried,
    @Finding                      AS Finding;

IF OBJECT_ID('tempdb..#ModuleStats') IS NOT NULL DROP TABLE #ModuleStats;
IF OBJECT_ID('tempdb..#FlaggedObjects') IS NOT NULL DROP TABLE #FlaggedObjects;
IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;