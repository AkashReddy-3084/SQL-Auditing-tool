SET NOCOUNT ON;

/* 13.3.1 - Table/column definitions documented with business context
   Read-only. Measures MS_Description extended-property coverage on user tables and columns. */

DECLARE @IsAzureSqlDb bit =
    CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#DocCoverage') IS NOT NULL
    DROP TABLE #DocCoverage;

CREATE TABLE #DocCoverage
(
    DatabaseName      sysname NOT NULL,
    TotalTables       int     NOT NULL,
    DocumentedTables  int     NOT NULL,
    TotalColumns      int     NOT NULL,
    DocumentedColumns int     NOT NULL
);

DECLARE @ProbeSql nvarchar(max) = N'
SELECT
    DB_NAME() AS DatabaseName,
    (SELECT COUNT(*)
       FROM sys.tables AS t
      WHERE t.is_ms_shipped = 0) AS TotalTables,
    (SELECT COUNT(*)
       FROM sys.tables AS t
      WHERE t.is_ms_shipped = 0
        AND EXISTS (SELECT 1
                      FROM sys.extended_properties AS ep
                     WHERE ep.class = 1
                       AND ep.major_id = t.object_id
                       AND ep.minor_id = 0
                       AND ep.name = N''MS_Description''
                       AND LTRIM(RTRIM(CONVERT(nvarchar(max), ep.value))) <> N'''')) AS DocumentedTables,
    (SELECT COUNT(*)
       FROM sys.tables AS t
       JOIN sys.columns AS c ON c.object_id = t.object_id
      WHERE t.is_ms_shipped = 0) AS TotalColumns,
    (SELECT COUNT(*)
       FROM sys.tables AS t
       JOIN sys.columns AS c ON c.object_id = t.object_id
      WHERE t.is_ms_shipped = 0
        AND EXISTS (SELECT 1
                      FROM sys.extended_properties AS ep
                     WHERE ep.class = 1
                       AND ep.major_id = c.object_id
                       AND ep.minor_id = c.column_id
                       AND ep.name = N''MS_Description''
                       AND LTRIM(RTRIM(CONVERT(nvarchar(max), ep.value))) <> N'''')) AS DocumentedColumns;';

IF @IsAzureSqlDb = 1
BEGIN
    /* Azure SQL Database: cross-database queries are not supported; inspect the current database only. */
    BEGIN TRY
        INSERT INTO #DocCoverage (DatabaseName, TotalTables, DocumentedTables, TotalColumns, DocumentedColumns)
        EXEC sp_executesql @ProbeSql;
    END TRY
    BEGIN CATCH
        /* Ignore databases that cannot be inspected. */
    END CATCH
END
ELSE
BEGIN
    DECLARE @DbName sysname;
    DECLARE @Exec nvarchar(max);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
          FROM sys.databases AS d
         WHERE d.database_id > 4
           AND d.state = 0
           AND d.is_in_standby = 0
           AND d.source_database_id IS NULL
           AND HAS_DBACCESS(d.name) = 1
         ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Exec = N'USE ' + QUOTENAME(@DbName) + N'; ' + @ProbeSql;

        BEGIN TRY
            INSERT INTO #DocCoverage (DatabaseName, TotalTables, DocumentedTables, TotalColumns, DocumentedColumns)
            EXEC sp_executesql @Exec;
        END TRY
        BEGIN CATCH
            /* Skip databases that are offline, recovering, or otherwise inaccessible. */
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @DbCount    int,
        @TotalTab   bigint,
        @DocTab     bigint,
        @TotalCol   bigint,
        @DocCol     bigint;

SELECT @DbCount  = COUNT(*),
       @TotalTab = ISNULL(SUM(CAST(TotalTables AS bigint)), 0),
       @DocTab   = ISNULL(SUM(CAST(DocumentedTables AS bigint)), 0),
       @TotalCol = ISNULL(SUM(CAST(TotalColumns AS bigint)), 0),
       @DocCol   = ISNULL(SUM(CAST(DocumentedColumns AS bigint)), 0)
  FROM #DocCoverage;

DECLARE @DbList nvarchar(max);

SELECT @DbList = STUFF((SELECT N', ' + d.DatabaseName
                          FROM #DocCoverage AS d
                         ORDER BY d.DatabaseName
                           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @WorstDbs nvarchar(max);

SELECT @WorstDbs = STUFF((SELECT TOP (5) N'; ' + x.DatabaseName
                                 + N' (tables ' + CAST(x.DocumentedTables AS varchar(20)) + N'/' + CAST(x.TotalTables AS varchar(20))
                                 + N', columns ' + CAST(x.DocumentedColumns AS varchar(20)) + N'/' + CAST(x.TotalColumns AS varchar(20)) + N')'
                            FROM #DocCoverage AS x
                           WHERE x.TotalTables > 0
                           ORDER BY (CAST(x.DocumentedTables AS decimal(19,4)) / NULLIF(x.TotalTables, 0)) ASC,
                                    x.DatabaseName ASC
                             FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @TablePct decimal(5,2) =
    CASE WHEN @TotalTab = 0 THEN CAST(0 AS decimal(5,2))
         ELSE CAST(@DocTab * 100.0 / @TotalTab AS decimal(5,2)) END;

DECLARE @ColumnPct decimal(5,2) =
    CASE WHEN @TotalCol = 0 THEN CAST(0 AS decimal(5,2))
         ELSE CAST(@DocCol * 100.0 / @TotalCol AS decimal(5,2)) END;

DECLARE @WeakestPct decimal(5,2) =
    CASE WHEN @TablePct < @ColumnPct THEN @TablePct ELSE @ColumnPct END;

DECLARE @Result   nvarchar(20),
        @Score    int,
        @Finding  nvarchar(max);

DECLARE @Coverage nvarchar(max) =
    N'Table descriptions: ' + CAST(@DocTab AS varchar(20)) + N'/' + CAST(@TotalTab AS varchar(20))
  + N' (' + CONVERT(varchar(10), @TablePct) + N'%). Column descriptions: '
  + CAST(@DocCol AS varchar(20)) + N'/' + CAST(@TotalCol AS varchar(20))
  + N' (' + CONVERT(varchar(10), @ColumnPct) + N'%). Databases inspected: ' + CAST(@DbCount AS varchar(20)) + N'.';

IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No accessible user database was found on this instance, so table/column business documentation coverage could not be measured and no evidence of documented business context exists.';
END
ELSE IF @TotalTab = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No user tables exist in the ' + CAST(@DbCount AS varchar(20))
                 + N' inspected database(s), so no table/column definitions are documented with business context.';
END
ELSE IF @WeakestPct >= 90
BEGIN
    SET @Score = 3;
    SET @Finding = N'Table and column definitions are documented with business context via MS_Description extended properties. ' + @Coverage;
END
ELSE IF @WeakestPct >= 70
BEGIN
    SET @Score = 2;
    SET @Finding = N'Business-context documentation is broadly present but incomplete. ' + @Coverage
                 + N' Lowest-coverage databases: ' + ISNULL(@WorstDbs, N'n/a') + N'.';
END
ELSE IF @WeakestPct >= 30
BEGIN
    SET @Score = 1;
    SET @Finding = N'Business-context documentation exists for only part of the schema. ' + @Coverage
                 + N' Lowest-coverage databases: ' + ISNULL(@WorstDbs, N'n/a') + N'.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'Table and column definitions are essentially undocumented: no meaningful MS_Description business context is recorded. ' + @Coverage
                 + N' Lowest-coverage databases: ' + ISNULL(@WorstDbs, N'n/a') + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DECLARE @DatabaseQueried nvarchar(max) = ISNULL(@DbList, N'None');

IF OBJECT_ID('tempdb..#DocCoverage') IS NOT NULL
    DROP TABLE #DocCoverage;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;