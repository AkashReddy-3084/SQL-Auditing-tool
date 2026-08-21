SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;
IF OBJECT_ID('tempdb..#ModuleScan') IS NOT NULL DROP TABLE #ModuleScan;

CREATE TABLE #Databases
(
    DbId         INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DatabaseName SYSNAME NOT NULL
);

CREATE TABLE #ModuleScan
(
    DatabaseName SYSNAME NOT NULL,
    SchemaName   SYSNAME NOT NULL,
    ObjectName   SYSNAME NOT NULL,
    ObjectType   NVARCHAR(60) NOT NULL,
    HasCursor    BIT NOT NULL,
    HasWhileLoop BIT NOT NULL
);

DECLARE @IsAzureSqlDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF @IsAzureSqlDb = 1
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
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1
    ORDER BY d.name;
END

DECLARE @Sql       NVARCHAR(MAX);
DECLARE @Db        SYSNAME;
DECLARE @Prefix    NVARCHAR(300);
DECLARE @DbLiteral NVARCHAR(300);
DECLARE @i         INT = 1;
DECLARE @n         INT = 0;

SELECT @n = COUNT(*) FROM #Databases;

WHILE @i <= @n
BEGIN
    SELECT @Db = DatabaseName FROM #Databases WHERE DbId = @i;

    SET @Prefix    = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@Db) + N'.' END;
    SET @DbLiteral = QUOTENAME(@Db, '''');

    SET @Sql = N'
        SELECT CONVERT(SYSNAME, N' + @DbLiteral + N') AS DatabaseName,
               s.name       AS SchemaName,
               o.name       AS ObjectName,
               o.type_desc  AS ObjectType,
               CASE WHEN m.definition COLLATE Latin1_General_CI_AS LIKE N''%DECLARE%CURSOR%FOR%''
                      OR m.definition COLLATE Latin1_General_CI_AS LIKE N''%FETCH NEXT%''
                      OR m.definition COLLATE Latin1_General_CI_AS LIKE N''%@@FETCH_STATUS%''
                      OR m.definition COLLATE Latin1_General_CI_AS LIKE N''%CURSOR_STATUS%''
                    THEN 1 ELSE 0 END AS HasCursor,
               CASE WHEN m.definition COLLATE Latin1_General_CI_AS LIKE N''%WHILE %''
                      OR m.definition COLLATE Latin1_General_CI_AS LIKE N''%WHILE(%''
                    THEN 1 ELSE 0 END AS HasWhileLoop
        FROM ' + @Prefix + N'sys.sql_modules AS m
        INNER JOIN ' + @Prefix + N'sys.objects AS o
                ON o.object_id = m.object_id
        INNER JOIN ' + @Prefix + N'sys.schemas AS s
                ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0
          AND o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'', ''V'')
          AND m.definition IS NOT NULL;';

    BEGIN TRY
        INSERT INTO #ModuleScan (DatabaseName, SchemaName, ObjectName, ObjectType, HasCursor, HasWhileLoop)
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        PRINT N'Skipped database ' + @Db + N': ' + ERROR_MESSAGE();
    END CATCH

    SET @i = @i + 1;
END

DECLARE @TotalModules  INT;
DECLARE @RowByRow      INT;
DECLARE @CursorModules INT;
DECLARE @WhileOnly     INT;
DECLARE @ScannedDbs    INT;

SELECT @TotalModules  = COUNT(*),
       @RowByRow      = SUM(CASE WHEN HasCursor = 1 OR HasWhileLoop = 1 THEN 1 ELSE 0 END),
       @CursorModules = SUM(CASE WHEN HasCursor = 1 THEN 1 ELSE 0 END),
       @WhileOnly     = SUM(CASE WHEN HasCursor = 0 AND HasWhileLoop = 1 THEN 1 ELSE 0 END)
FROM #ModuleScan;

SET @TotalModules  = ISNULL(@TotalModules, 0);
SET @RowByRow      = ISNULL(@RowByRow, 0);
SET @CursorModules = ISNULL(@CursorModules, 0);
SET @WhileOnly     = ISNULL(@WhileOnly, 0);

SELECT @ScannedDbs = COUNT(*) FROM #Databases;

DECLARE @Pct DECIMAL(5,2) =
    CASE WHEN @TotalModules = 0 THEN CONVERT(DECIMAL(5,2), 0)
         ELSE CONVERT(DECIMAL(5,2), (@RowByRow * 100.0) / @TotalModules)
    END;

DECLARE @DatabaseQueried NVARCHAR(MAX) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #Databases AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

IF @DatabaseQueried IS NULL
    SET @DatabaseQueried = N'None - no accessible user databases';

DECLARE @TopOffenders NVARCHAR(MAX) =
    STUFF((SELECT TOP (10) N'; ' + ms.DatabaseName + N'.' + ms.SchemaName + N'.' + ms.ObjectName
                  + N' (' + ms.ObjectType
                  + CASE WHEN ms.HasCursor = 1 THEN N', cursor' ELSE N'' END
                  + CASE WHEN ms.HasWhileLoop = 1 THEN N', while-loop' ELSE N'' END + N')'
           FROM #ModuleScan AS ms
           WHERE ms.HasCursor = 1 OR ms.HasWhileLoop = 1
           ORDER BY ms.HasCursor DESC, ms.DatabaseName, ms.SchemaName, ms.ObjectName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Score   INT;
DECLARE @Result  NVARCHAR(20);
DECLARE @Finding NVARCHAR(MAX);

IF @TotalModules = 0
    SET @Score = 3;
ELSE IF @Pct = 0
    SET @Score = 3;
ELSE IF @Pct <= 10.00
    SET @Score = 2;
ELSE IF @Pct <= 25.00
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

IF @TotalModules = 0
    SET @Finding = N'Scanned ' + CONVERT(NVARCHAR(20), @ScannedDbs)
                 + N' accessible user database(s) and found no user-defined T-SQL modules (procedures, functions, triggers or views), so no row-by-row processing logic is implemented in the database tier.';
ELSE
    SET @Finding = N'Scanned ' + CONVERT(NVARCHAR(20), @ScannedDbs) + N' accessible user database(s) containing '
                 + CONVERT(NVARCHAR(20), @TotalModules) + N' user-defined T-SQL module(s). '
                 + CONVERT(NVARCHAR(20), @RowByRow) + N' module(s) ('
                 + CONVERT(NVARCHAR(20), @Pct) + N'%) use row-by-row processing constructs: '
                 + CONVERT(NVARCHAR(20), @CursorModules) + N' use cursors/FETCH loops and '
                 + CONVERT(NVARCHAR(20), @WhileOnly) + N' use iterative WHILE loops without a cursor. '
                 + CASE WHEN @TopOffenders IS NULL
                        THEN N'All modules are written with set-based statements.'
                        ELSE N'Top offending modules: ' + @TopOffenders + N'.'
                   END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;