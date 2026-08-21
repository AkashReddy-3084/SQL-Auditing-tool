SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsSingleDb BIT = CASE WHEN @EngineEdition IN (5, 6, 9, 11) THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#ModuleScan') IS NOT NULL
    DROP TABLE #ModuleScan;

CREATE TABLE #ModuleScan
(
    DatabaseName SYSNAME       NOT NULL,
    SchemaName   SYSNAME       NOT NULL,
    ObjectName   SYSNAME       NOT NULL,
    ObjectType   NVARCHAR(60)  NULL,
    HasCursor    BIT           NOT NULL,
    HasRowLoop   BIT           NOT NULL
);

DECLARE @Databases TABLE
(
    RowId        INT IDENTITY(1, 1) NOT NULL,
    DatabaseName SYSNAME            NOT NULL
);

IF @IsSingleDb = 1
BEGIN
    INSERT INTO #ModuleScan (DatabaseName, SchemaName, ObjectName, ObjectType, HasCursor, HasRowLoop)
    SELECT DB_NAME(),
           s.name,
           o.name,
           o.type_desc,
           CASE
               WHEN m.definition COLLATE Latin1_General_CI_AS LIKE '%DECLARE%CURSOR%'
                 OR m.definition COLLATE Latin1_General_CI_AS LIKE '%FETCH NEXT%'
                 OR m.definition COLLATE Latin1_General_CI_AS LIKE '%OPEN%FETCH%'
               THEN 1
               ELSE 0
           END,
           CASE
               WHEN m.definition COLLATE Latin1_General_CI_AS LIKE '%WHILE%'
                AND (   m.definition COLLATE Latin1_General_CI_AS LIKE '%@@FETCH_STATUS%'
                     OR m.definition COLLATE Latin1_General_CI_AS LIKE '%TOP (1)%'
                     OR m.definition COLLATE Latin1_General_CI_AS LIKE '%TOP 1 %'
                     OR m.definition COLLATE Latin1_General_CI_AS LIKE '%SET ROWCOUNT%')
               THEN 1
               ELSE 0
           END
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o
        ON o.object_id = m.object_id
    INNER JOIN sys.schemas AS s
        ON s.schema_id = o.schema_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('P', 'FN', 'IF', 'TF', 'TR', 'V');
END
ELSE
BEGIN
    INSERT INTO @Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_in_standby = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1
    ORDER BY d.name;

    DECLARE @RowId INT = 1;
    DECLARE @MaxRowId INT = (SELECT COUNT(*) FROM @Databases);
    DECLARE @DbName SYSNAME;
    DECLARE @Sql NVARCHAR(MAX);

    WHILE @RowId <= @MaxRowId
    BEGIN
        SELECT @DbName = d.DatabaseName
        FROM @Databases AS d
        WHERE d.RowId = @RowId;

        SET @Sql = N'
        INSERT INTO #ModuleScan (DatabaseName, SchemaName, ObjectName, ObjectType, HasCursor, HasRowLoop)
        SELECT ' + QUOTENAME(@DbName, '''') + N',
               s.name,
               o.name,
               o.type_desc,
               CASE
                   WHEN m.definition COLLATE Latin1_General_CI_AS LIKE ''%DECLARE%CURSOR%''
                     OR m.definition COLLATE Latin1_General_CI_AS LIKE ''%FETCH NEXT%''
                     OR m.definition COLLATE Latin1_General_CI_AS LIKE ''%OPEN%FETCH%''
                   THEN 1
                   ELSE 0
               END,
               CASE
                   WHEN m.definition COLLATE Latin1_General_CI_AS LIKE ''%WHILE%''
                    AND (   m.definition COLLATE Latin1_General_CI_AS LIKE ''%@@FETCH_STATUS%''
                         OR m.definition COLLATE Latin1_General_CI_AS LIKE ''%TOP (1)%''
                         OR m.definition COLLATE Latin1_General_CI_AS LIKE ''%TOP 1 %''
                         OR m.definition COLLATE Latin1_General_CI_AS LIKE ''%SET ROWCOUNT%'')
                   THEN 1
                   ELSE 0
               END
        FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m
        INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o
            ON o.object_id = m.object_id
        INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s
            ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0
          AND o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'', ''V'');';

        BEGIN TRY
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            SET @Sql = NULL; -- database unreadable at scan time; leave it out of the sample
        END CATCH;

        SET @RowId = @RowId + 1;
    END
END

DECLARE @TotalModules   INT;
DECLARE @CursorModules  INT;
DECLARE @LoopModules    INT;
DECLARE @FlaggedModules INT;
DECLARE @Percent        DECIMAL(9, 2);
DECLARE @DbList         NVARCHAR(4000);
DECLARE @TopDbs         NVARCHAR(1000);
DECLARE @Result         NVARCHAR(20);
DECLARE @Score          INT;
DECLARE @Finding        NVARCHAR(4000);

SELECT @TotalModules   = COUNT(*),
       @CursorModules  = SUM(CASE WHEN HasCursor = 1 THEN 1 ELSE 0 END),
       @LoopModules    = SUM(CASE WHEN HasRowLoop = 1 THEN 1 ELSE 0 END),
       @FlaggedModules = SUM(CASE WHEN HasCursor = 1 OR HasRowLoop = 1 THEN 1 ELSE 0 END)
FROM #ModuleScan;

SET @TotalModules   = ISNULL(@TotalModules, 0);
SET @CursorModules  = ISNULL(@CursorModules, 0);
SET @LoopModules    = ISNULL(@LoopModules, 0);
SET @FlaggedModules = ISNULL(@FlaggedModules, 0);

IF @IsSingleDb = 1
    SET @DbList = DB_NAME();
ELSE
    SET @DbList = LEFT(ISNULL(STUFF((SELECT N', ' + d.DatabaseName
                                     FROM @Databases AS d
                                     ORDER BY d.DatabaseName
                                     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'None'), 4000);

SET @TopDbs = ISNULL(STUFF((SELECT TOP (3) N'; ' + ms.DatabaseName + N' (' + CAST(COUNT(*) AS NVARCHAR(20)) + N')'
                            FROM #ModuleScan AS ms
                            WHERE ms.HasCursor = 1
                               OR ms.HasRowLoop = 1
                            GROUP BY ms.DatabaseName
                            ORDER BY COUNT(*) DESC
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

IF @TotalModules = 0
BEGIN
    SET @Percent = 0.00;
    SET @Score = 3;
    SET @Finding = N'No user-defined T-SQL modules (procedures, functions, triggers, views) were found in the scanned databases, so no cursor or row-by-row loop logic exists that would require a set-based rewrite. Databases scanned: ' + @DbList + N'.';
END
ELSE
BEGIN
    SET @Percent = CAST(@FlaggedModules * 100.0 / @TotalModules AS DECIMAL(9, 2));

    SET @Score = CASE
                     WHEN @FlaggedModules = 0 THEN 3
                     WHEN @Percent <= 5.00 THEN 2
                     WHEN @Percent <= 15.00 THEN 1
                     ELSE 0
                 END;

    SET @Finding = N'Scanned ' + CAST(@TotalModules AS NVARCHAR(20)) + N' user T-SQL module(s); '
                 + CAST(@FlaggedModules AS NVARCHAR(20)) + N' (' + CAST(@Percent AS NVARCHAR(20))
                 + N'%) still contain row-by-row processing: ' + CAST(@CursorModules AS NVARCHAR(20))
                 + N' with cursor constructs (DECLARE CURSOR / FETCH NEXT) and ' + CAST(@LoopModules AS NVARCHAR(20))
                 + N' with row-at-a-time WHILE loops (@@FETCH_STATUS, TOP (1) or SET ROWCOUNT). '
                 + N'Top databases by flagged modules: ' + @TopDbs + N'. Databases scanned: ' + @DbList + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result  AS Result,
       @Score   AS Score,
       @DbList  AS DatabaseQueried,
       @Finding AS Finding;

IF OBJECT_ID('tempdb..#ModuleScan') IS NOT NULL
    DROP TABLE #ModuleScan;