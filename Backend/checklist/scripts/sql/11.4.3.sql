/*
    Checklist Item : 11.4.3 - Data validation tests run post-deployment (counts, schema checks)
    Scope          : SERVER (enumerates every accessible user database)
    Read-only      : Yes - catalog views only, no data, schema or configuration changes
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @Findings TABLE
(
    DatabaseName     SYSNAME,
    TestObjectCount  INT,
    HasTestFramework BIT,
    ResultLogCount   INT
);

DECLARE @InnerSql NVARCHAR(MAX) = N'
SELECT
    DB_NAME() AS DatabaseName,
    (
        SELECT COUNT(*)
        FROM sys.objects AS o
        INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.type IN (''P'',''FN'',''IF'',''TF'',''V'')
          AND o.is_ms_shipped = 0
          AND (
                s.name IN (''tSQLt'',''test'',''tests'',''unittest'',''unittests'',''validation'',''dbtest'')
             OR o.name LIKE ''%validat%''
             OR o.name LIKE ''%rowcount%''
             OR o.name LIKE ''%row[_]count%''
             OR o.name LIKE ''%schemacheck%''
             OR o.name LIKE ''%schema[_]check%''
             OR o.name LIKE ''%datacheck%''
             OR o.name LIKE ''%data[_]check%''
             OR o.name LIKE ''%smoketest%''
             OR o.name LIKE ''%smoke[_]test%''
             OR o.name LIKE ''%postdeploy%''
             OR o.name LIKE ''%post[_]deploy%''
             OR o.name LIKE ''test[_]%''
             OR o.name LIKE ''ut[_]%''
          )
    ) AS TestObjectCount,
    CASE WHEN EXISTS
    (
        SELECT 1
        FROM sys.schemas
        WHERE name IN (''tSQLt'',''test'',''tests'',''unittest'',''unittests'')
    ) THEN 1 ELSE 0 END AS HasTestFramework,
    (
        SELECT COUNT(*)
        FROM sys.tables AS t
        WHERE t.is_ms_shipped = 0
          AND (
                t.name LIKE ''%validationresult%''    OR t.name LIKE ''%validation[_]result%''
             OR t.name LIKE ''%validationlog%''       OR t.name LIKE ''%validation[_]log%''
             OR t.name LIKE ''%testresult%''          OR t.name LIKE ''%test[_]result%''
             OR t.name LIKE ''%testrun%''             OR t.name LIKE ''%test[_]run%''
             OR t.name LIKE ''%deploymentlog%''       OR t.name LIKE ''%deployment[_]log%''
             OR t.name LIKE ''%deploymenthistory%''   OR t.name LIKE ''%deployment[_]history%''
             OR t.name LIKE ''%releaselog%''          OR t.name LIKE ''%release[_]log%''
          )
    ) AS ResultLogCount;';

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    -- Azure SQL Database: cross-database access is unavailable, inspect the current database only.
    BEGIN TRY
        INSERT INTO @Findings (DatabaseName, TestObjectCount, HasTestFramework, ResultLogCount)
        EXEC sys.sp_executesql @InnerSql;
    END TRY
    BEGIN CATCH
        SET @InnerSql = @InnerSql;
    END CATCH
END
ELSE
BEGIN
    DECLARE @DbName SYSNAME;
    DECLARE @ExecTarget NVARCHAR(400);

    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ExecTarget = QUOTENAME(@DbName) + N'.sys.sp_executesql';

        BEGIN TRY
            INSERT INTO @Findings (DatabaseName, TestObjectCount, HasTestFramework, ResultLogCount)
            EXEC @ExecTarget @InnerSql;
        END TRY
        BEGIN CATCH
            SET @ExecTarget = @ExecTarget;
        END CATCH

        FETCH NEXT FROM db_cur INTO @DbName;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @TotalDbs     INT = (SELECT COUNT(*) FROM @Findings);
DECLARE @DbsWithTests INT = (SELECT COUNT(*) FROM @Findings WHERE TestObjectCount > 0 OR HasTestFramework = 1);
DECLARE @DbsWithLogs  INT = (SELECT COUNT(*) FROM @Findings WHERE ResultLogCount > 0);
DECLARE @DbsWithBoth  INT = (SELECT COUNT(*) FROM @Findings WHERE (TestObjectCount > 0 OR HasTestFramework = 1) AND ResultLogCount > 0);

DECLARE @ScannedList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N', ' + f.DatabaseName
                  FROM @Findings AS f
                  ORDER BY f.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @TestedList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N', ' + f.DatabaseName
                  FROM @Findings AS f
                  WHERE f.TestObjectCount > 0 OR f.HasTestFramework = 1
                  ORDER BY f.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @UntestedList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N', ' + f.DatabaseName
                  FROM @Findings AS f
                  WHERE f.TestObjectCount = 0 AND f.HasTestFramework = 0
                  ORDER BY f.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @Result  NVARCHAR(20);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(MAX);

IF @TotalDbs = 0
BEGIN
    SET @Score  = 1;
    SET @Finding = N'No accessible user database could be inspected on this instance, so the presence of post-deployment data validation tests (row counts, schema checks) could not be confirmed.';
END
ELSE IF @DbsWithBoth > 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'Data validation test artifacts are present and their execution is being recorded. '
                 + CAST(@DbsWithTests AS NVARCHAR(10)) + N' of ' + CAST(@TotalDbs AS NVARCHAR(10))
                 + N' accessible user database(s) contain validation/test modules ('
                 + LEFT(@TestedList, 400) + N'), and ' + CAST(@DbsWithLogs AS NVARCHAR(10))
                 + N' database(s) also contain test-result or deployment/release log tables that evidence post-deployment validation runs.'
                 + CASE WHEN @UntestedList <> N'none'
                        THEN N' Databases with no validation test objects: ' + LEFT(@UntestedList, 400) + N'.'
                        ELSE N'' END;
END
ELSE IF @DbsWithTests > 0
BEGIN
    SET @Score  = 2;
    SET @Finding = N'Data validation/test modules exist in ' + CAST(@DbsWithTests AS NVARCHAR(10)) + N' of '
                 + CAST(@TotalDbs AS NVARCHAR(10)) + N' accessible user database(s) (' + LEFT(@TestedList, 400)
                 + N'), but no test-result, deployment or release log table was found in any database, so there is only partial evidence that these validation tests are executed after each deployment.';
END
ELSE
BEGIN
    SET @Score  = 1;
    SET @Finding = N'No data validation test artifacts were found in any of the ' + CAST(@TotalDbs AS NVARCHAR(10))
                 + N' accessible user database(s) (' + LEFT(@ScannedList, 400)
                 + N'). No tSQLt/test/validation schema, no row-count or schema-check validation module, and no test-result or deployment log table is present, indicating post-deployment data validation tests are not implemented in the database tier.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result                      AS Result,
    @Score                       AS Score,
    LEFT(@ScannedList, 900)      AS DatabaseQueried,
    @Finding                     AS Finding;