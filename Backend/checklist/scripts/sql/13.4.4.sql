SET NOCOUNT ON;

/* 13.4.4 - Code is self-documenting or well-commented for complex logic.
   Read-only inspection of sys.sql_modules across accessible user databases. */

DECLARE @IsSingleDbEngine bit =
    CASE WHEN CONVERT(int, ISNULL(SERVERPROPERTY('EngineEdition'), 2)) IN (5, 6, 11) THEN 1 ELSE 0 END;

DECLARE @Databases TABLE (DatabaseName sysname NOT NULL);
DECLARE @ModuleStats TABLE
(
    DatabaseName             sysname NOT NULL,
    TotalComplexModules      int     NOT NULL,
    UncommentedComplexModules int    NOT NULL
);

IF @IsSingleDbEngine = 1
BEGIN
    INSERT INTO @Databases (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO @Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @DbName      sysname;
DECLARE @Sql         nvarchar(max);
DECLARE @Total       int;
DECLARE @Uncommented int;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM @Databases ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Total = 0;
    SET @Uncommented = 0;

    SET @Sql =
        N'SELECT @TotalOut = ISNULL(COUNT(*), 0),' + NCHAR(10) +
        N'       @UncommentedOut = ISNULL(SUM(CASE WHEN m.definition NOT LIKE ''%--%''' + NCHAR(10) +
        N'                                          AND m.definition NOT LIKE ''%/*%''' + NCHAR(10) +
        N'                                         THEN 1 ELSE 0 END), 0)' + NCHAR(10) +
        N'FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m' + NCHAR(10) +
        N'INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o' + NCHAR(10) +
        N'    ON o.object_id = m.object_id' + NCHAR(10) +
        N'WHERE o.is_ms_shipped = 0' + NCHAR(10) +
        N'  AND o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'')' + NCHAR(10) +
        N'  AND m.definition IS NOT NULL' + NCHAR(10) +
        N'  AND (DATALENGTH(m.definition) >= 4000' + NCHAR(10) +
        N'       OR ((DATALENGTH(m.definition) - DATALENGTH(REPLACE(m.definition, CHAR(10), N''''))) / 2) >= 50);';

    BEGIN TRY
        EXEC sp_executesql
             @Sql,
             N'@TotalOut int OUTPUT, @UncommentedOut int OUTPUT',
             @TotalOut = @Total OUTPUT,
             @UncommentedOut = @Uncommented OUTPUT;

        INSERT INTO @ModuleStats (DatabaseName, TotalComplexModules, UncommentedComplexModules)
        VALUES (@DbName, ISNULL(@Total, 0), ISNULL(@Uncommented, 0));
    END TRY
    BEGIN CATCH
        /* database unreadable at this moment - skip it rather than abort the audit */
        SET @Total = NULL;
    END CATCH

    FETCH NEXT FROM db_cur INTO @DbName;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @DbCount        int = ISNULL((SELECT COUNT(*) FROM @ModuleStats), 0);
DECLARE @TotalComplex   int = ISNULL((SELECT SUM(TotalComplexModules) FROM @ModuleStats), 0);
DECLARE @TotalUncomment int = ISNULL((SELECT SUM(UncommentedComplexModules) FROM @ModuleStats), 0);

DECLARE @Pct decimal(9,2) =
    ISNULL(CONVERT(decimal(9,2), 100.0 * @TotalUncomment / NULLIF(@TotalComplex, 0)), 0.00);

DECLARE @DbList nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + s.DatabaseName
                  FROM @ModuleStats AS s
                  ORDER BY s.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @Detail nvarchar(max) =
    ISNULL(STUFF((SELECT TOP (5) N'; ' + s.DatabaseName + N' ' +
                         CONVERT(nvarchar(20), s.UncommentedComplexModules) + N'/' +
                         CONVERT(nvarchar(20), s.TotalComplexModules)
                  FROM @ModuleStats AS s
                  WHERE s.TotalComplexModules > 0
                  ORDER BY s.UncommentedComplexModules DESC, s.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @Score  int;
DECLARE @Result nvarchar(10);

IF @TotalComplex = 0
    SET @Score = 3;
ELSE IF @Pct = 0
    SET @Score = 3;
ELSE IF @Pct < 5
    SET @Score = 2;
ELSE IF @Pct < 25
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN N'PASS' ELSE N'FAIL' END;

DECLARE @Finding nvarchar(max);

IF @DbCount = 0
    SET @Finding = N'No accessible user database could be inspected, so comment coverage of complex code could not be measured.';
ELSE IF @TotalComplex = 0
    SET @Finding = N'Inspected ' + CONVERT(nvarchar(20), @DbCount) +
                   N' user database(s); no programmable object met the complexity threshold (2000+ characters or 50+ lines), so there is no complex logic left uncommented.';
ELSE
    SET @Finding = N'Inspected ' + CONVERT(nvarchar(20), @DbCount) + N' user database(s) and found ' +
                   CONVERT(nvarchar(20), @TotalComplex) + N' complex module(s) (2000+ characters or 50+ lines), of which ' +
                   CONVERT(nvarchar(20), @TotalUncomment) + N' (' + CONVERT(nvarchar(20), @Pct) +
                   N'%) contain no comment at all. Uncommented/complex per database: ' + @Detail + N'.';

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @DbList  AS DatabaseQueried,
    @Finding AS Finding;