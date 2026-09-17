SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#DbResults') IS NOT NULL
    DROP TABLE #DbResults;

CREATE TABLE #DbResults
(
    DatabaseName SYSNAME NOT NULL,
    tSQLtInstalled BIT NOT NULL,
    TestClassCount INT NOT NULL,
    tSQLtTestCount INT NOT NULL,
    OtherTestProcCount INT NOT NULL,
    TransformationObjectCount INT NOT NULL
);

DECLARE @Result NVARCHAR(50);
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(4000) = N'None';
DECLARE @Finding NVARCHAR(4000) = N'No database found to be queried';

DECLARE @IsAzureSqlDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @Databases TABLE (RowId INT IDENTITY(1, 1) PRIMARY KEY, DatabaseName SYSNAME NOT NULL);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO @Databases (DatabaseName)
    SELECT DB_NAME()
    WHERE DB_NAME() NOT IN ('master', 'model', 'msdb', 'tempdb');
END
ELSE
BEGIN
    INSERT INTO @Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name NOT IN ('master', 'model', 'msdb', 'tempdb')
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1
    ORDER BY d.name;
END

DECLARE @RowId INT = 1;
DECLARE @MaxRowId INT = (SELECT ISNULL(MAX(RowId), 0) FROM @Databases);
DECLARE @DbName SYSNAME;
DECLARE @Prefix NVARCHAR(300);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @SkippedCount INT = 0;

WHILE @RowId <= @MaxRowId
BEGIN
    SELECT @DbName = DatabaseName FROM @Databases WHERE RowId = @RowId;

    IF @DbName IS NOT NULL
    BEGIN
        SET @Prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;

        SET @Sql = N'
INSERT INTO #DbResults (DatabaseName, tSQLtInstalled, TestClassCount, tSQLtTestCount, OtherTestProcCount, TransformationObjectCount)
SELECT
    @pDbName,
    CASE WHEN EXISTS (SELECT 1 FROM ' + @Prefix + N'sys.schemas AS sc WHERE sc.name = ''tSQLt'')
          AND EXISTS (SELECT 1
                      FROM ' + @Prefix + N'sys.procedures AS p
                      INNER JOIN ' + @Prefix + N'sys.schemas AS s ON p.schema_id = s.schema_id
                      WHERE s.name = ''tSQLt'' AND p.name IN (''RunAll'', ''Run'', ''NewTestClass''))
         THEN 1 ELSE 0 END,
    (SELECT COUNT(*)
     FROM ' + @Prefix + N'sys.extended_properties AS ep
     INNER JOIN ' + @Prefix + N'sys.schemas AS s ON ep.major_id = s.schema_id
     WHERE ep.class = 3 AND ep.name = ''tSQLt.TestClass''),
    (SELECT COUNT(*)
     FROM ' + @Prefix + N'sys.procedures AS p
     INNER JOIN ' + @Prefix + N'sys.schemas AS s ON p.schema_id = s.schema_id
     INNER JOIN ' + @Prefix + N'sys.extended_properties AS ep
         ON ep.class = 3 AND ep.major_id = s.schema_id AND ep.name = ''tSQLt.TestClass''
     WHERE p.name LIKE ''test%''),
    (SELECT COUNT(*)
     FROM ' + @Prefix + N'sys.procedures AS p
     INNER JOIN ' + @Prefix + N'sys.schemas AS s ON p.schema_id = s.schema_id
     WHERE s.name <> ''tSQLt''
       AND NOT EXISTS (SELECT 1
                       FROM ' + @Prefix + N'sys.extended_properties AS ep
                       WHERE ep.class = 3 AND ep.major_id = s.schema_id AND ep.name = ''tSQLt.TestClass'')
       AND (s.name LIKE ''%test%''
            OR p.name LIKE ''test[_]%''
            OR p.name LIKE ''ut[_]%''
            OR p.name LIKE ''sp[_]test%''
            OR p.name LIKE ''spTest%''
            OR p.name LIKE ''%unittest%''
            OR p.name LIKE ''%[_]test'')),
    (SELECT COUNT(*)
     FROM ' + @Prefix + N'sys.objects AS o
     INNER JOIN ' + @Prefix + N'sys.schemas AS s ON o.schema_id = s.schema_id
     WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'')
       AND o.is_ms_shipped = 0
       AND s.name <> ''tSQLt''
       AND NOT EXISTS (SELECT 1
                       FROM ' + @Prefix + N'sys.extended_properties AS ep
                       WHERE ep.class = 3 AND ep.major_id = s.schema_id AND ep.name = ''tSQLt.TestClass''));';

        BEGIN TRY
            EXEC sys.sp_executesql @Sql, N'@pDbName SYSNAME', @pDbName = @DbName;
        END TRY
        BEGIN CATCH
            SET @SkippedCount = @SkippedCount + 1;
        END CATCH
    END

    SET @RowId = @RowId + 1;
END

DECLARE @DbCount INT = (SELECT COUNT(*) FROM #DbResults);

IF @DbCount = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    DECLARE @DbWithtSQLtTests INT;
    DECLARE @DbWithOtherTests INT;
    DECLARE @DbWithtSQLtNoTests INT;
    DECLARE @DbWithTransformation INT;
    DECLARE @DbWithTransformationNoTests INT;
    DECLARE @TotalTests INT;
    DECLARE @TotalTransformationObjects INT;
    DECLARE @DbsWithTests NVARCHAR(1000);
    DECLARE @DbsWithoutTests NVARCHAR(1000);

    SELECT
        @DbWithtSQLtTests = SUM(CASE WHEN r.tSQLtInstalled = 1 AND r.TestClassCount > 0 AND r.tSQLtTestCount > 0 THEN 1 ELSE 0 END),
        @DbWithOtherTests = SUM(CASE WHEN NOT (r.tSQLtInstalled = 1 AND r.TestClassCount > 0 AND r.tSQLtTestCount > 0) AND r.OtherTestProcCount > 0 THEN 1 ELSE 0 END),
        @DbWithtSQLtNoTests = SUM(CASE WHEN r.tSQLtInstalled = 1 AND (r.TestClassCount = 0 OR r.tSQLtTestCount = 0) THEN 1 ELSE 0 END),
        @DbWithTransformation = SUM(CASE WHEN r.TransformationObjectCount > 0 THEN 1 ELSE 0 END),
        @DbWithTransformationNoTests = SUM(CASE WHEN r.TransformationObjectCount > 0
                                                 AND NOT (r.tSQLtInstalled = 1 AND r.TestClassCount > 0 AND r.tSQLtTestCount > 0)
                                                 AND r.OtherTestProcCount = 0 THEN 1 ELSE 0 END),
        @TotalTests = SUM(r.tSQLtTestCount + r.OtherTestProcCount),
        @TotalTransformationObjects = SUM(r.TransformationObjectCount)
    FROM #DbResults AS r;

    SET @DatabaseQueried = STUFF((SELECT N', ' + r.DatabaseName
                                  FROM #DbResults AS r
                                  ORDER BY r.DatabaseName
                                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(4000)'), 1, 2, N'');

    SET @DbsWithTests = STUFF((SELECT TOP (5) N', ' + r.DatabaseName
                               FROM #DbResults AS r
                               WHERE (r.tSQLtInstalled = 1 AND r.TestClassCount > 0 AND r.tSQLtTestCount > 0)
                                  OR r.OtherTestProcCount > 0
                               ORDER BY r.DatabaseName
                               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N'');

    SET @DbsWithoutTests = STUFF((SELECT TOP (5) N', ' + r.DatabaseName
                                  FROM #DbResults AS r
                                  WHERE r.TransformationObjectCount > 0
                                    AND NOT (r.tSQLtInstalled = 1 AND r.TestClassCount > 0 AND r.tSQLtTestCount > 0)
                                    AND r.OtherTestProcCount = 0
                                  ORDER BY r.DatabaseName
                                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N'');

    IF @DbWithTransformation = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'No user-defined stored procedures, functions or views were found in the ' + CAST(@DbCount AS NVARCHAR(10))
                     + N' database(s) examined, so there is no transformation logic requiring unit tests.';
    END
    ELSE IF @DbWithtSQLtTests > 0 AND @DbWithTransformationNoTests = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Unit tests cover transformation logic in all ' + CAST(@DbWithTransformation AS NVARCHAR(10))
                     + N' database(s) that contain programmable objects. ' + CAST(@DbWithtSQLtTests AS NVARCHAR(10))
                     + N' database(s) run a tSQLt suite (test classes marked with the tSQLt.TestClass extended property), '
                     + CAST(@TotalTests AS NVARCHAR(10)) + N' test procedure(s) in total against '
                     + CAST(@TotalTransformationObjects AS NVARCHAR(10)) + N' programmable object(s). Databases with tests: '
                     + ISNULL(@DbsWithTests, N'(none)') + N'.';
    END
    ELSE IF @DbWithtSQLtTests > 0 OR @DbWithOtherTests > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Unit testing is only partially adopted: ' + CAST(@DbWithtSQLtTests AS NVARCHAR(10))
                     + N' database(s) run a tSQLt suite and ' + CAST(@DbWithOtherTests AS NVARCHAR(10))
                     + N' database(s) contain procedures following unit-test naming conventions, but '
                     + CAST(@DbWithTransformationNoTests AS NVARCHAR(10)) + N' of ' + CAST(@DbWithTransformation AS NVARCHAR(10))
                     + N' database(s) holding transformation logic have no tests at all. Databases with tests: '
                     + ISNULL(@DbsWithTests, N'(none)') + N'. Databases without tests: ' + ISNULL(@DbsWithoutTests, N'(none)') + N'.';
    END
    ELSE IF @DbWithtSQLtNoTests > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'The tSQLt framework is installed in ' + CAST(@DbWithtSQLtNoTests AS NVARCHAR(10))
                     + N' database(s) but contains no executable tests (no schema carries the tSQLt.TestClass extended property, or no procedure is named test%). '
                     + CAST(@TotalTransformationObjects AS NVARCHAR(10)) + N' programmable object(s) across '
                     + CAST(@DbWithTransformation AS NVARCHAR(10)) + N' database(s) remain untested. Databases without tests: '
                     + ISNULL(@DbsWithoutTests, N'(none)') + N'.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No unit testing framework or test objects were found in any of the ' + CAST(@DbCount AS NVARCHAR(10))
                     + N' database(s) examined: the tSQLt schema is absent, no schema carries the tSQLt.TestClass extended property, and no procedure follows unit-test naming conventions. '
                     + CAST(@TotalTransformationObjects AS NVARCHAR(10)) + N' programmable object(s) implementing transformation logic across '
                     + CAST(@DbWithTransformation AS NVARCHAR(10)) + N' database(s) have no automated unit test coverage. Databases without tests: '
                     + ISNULL(@DbsWithoutTests, N'(none)') + N'.';
    END

    IF @SkippedCount > 0
        SET @Finding = @Finding + N' ' + CAST(@SkippedCount AS NVARCHAR(10)) + N' database(s) could not be inspected due to access or availability errors.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;