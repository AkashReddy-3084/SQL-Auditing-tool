-- Checklist: Sensitive data classified (SQL Data Discovery & Classification / labels)
-- Scope: DATABASE
-- Scoring: 0 = No classified columns found. 1 = 1-9 classified columns. 2 = 10-99 classified columns. 3 = >=100 classified columns.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current DB only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @ClassifiedCount INT = 0;
        DECLARE @TotalTables INT = 0;
        SELECT @ClassifiedCount = COUNT(DISTINCT c.object_id + c.column_id),
               @TotalTables = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        JOIN sys.columns c ON t.object_id = c.object_id
        LEFT JOIN sys.sensitivity_classifications sc ON t.object_id = sc.major_id AND c.column_id = sc.minor_id
        WHERE t.is_ms_shipped = 0;

        DECLARE @DbScore INT = 0;
        DECLARE @DbFinding NVARCHAR(MAX) = '';

        IF @ClassifiedCount >= 100 SET @DbScore = 3;
        ELSE IF @ClassifiedCount >= 10 SET @DbScore = 2;
        ELSE IF @ClassifiedCount >= 1 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        SET @DbFinding = CAST(@ClassifiedCount AS NVARCHAR) + '' classified columns found across '' + CAST(@TotalTables AS NVARCHAR) + '' user tables.'';

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@pDbName, @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
                DECLARE @ClassifiedCount INT = 0;
                DECLARE @TotalTables INT = 0;
                SELECT @ClassifiedCount = COUNT(DISTINCT c.object_id + c.column_id),
                       @TotalTables = COUNT(DISTINCT t.object_id)
                FROM sys.tables t
                JOIN sys.columns c ON t.object_id = c.object_id
                LEFT JOIN sys.sensitivity_classifications sc ON t.object_id = sc.major_id AND c.column_id = sc.minor_id
                WHERE t.is_ms_shipped = 0;

                DECLARE @DbScore INT = 0;
                DECLARE @DbFinding NVARCHAR(MAX) = '';

                IF @ClassifiedCount >= 100 SET @DbScore = 3;
                ELSE IF @ClassifiedCount >= 10 SET @DbScore = 2;
                ELSE IF @ClassifiedCount >= 1 SET @DbScore = 1;
                ELSE SET @DbScore = 0;

                SET @DbFinding = CAST(@ClassifiedCount AS NVARCHAR) + '' classified columns found across '' + CAST(@TotalTables AS NVARCHAR) + '' user tables.'';

                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (@pDbName, @DbScore, @DbFinding);
            ';
            EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;