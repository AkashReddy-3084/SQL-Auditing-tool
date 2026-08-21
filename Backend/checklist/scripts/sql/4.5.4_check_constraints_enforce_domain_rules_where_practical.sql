-- Checklist: Check constraints enforce domain rules where practical
-- Scope: DATABASE
-- Scoring: 0: No check constraints found. 1: <20% coverage. 2: 20-79% coverage. 3: >=80% coverage. 
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    BEGIN TRY
        SET @Sql = N'
        DECLARE @TotalTables INT;
        DECLARE @TablesWithCC INT;
        DECLARE @Pct FLOAT;
        DECLARE @FindingText NVARCHAR(MAX);

        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND type = ''U'';
        SELECT @TablesWithCC = COUNT(DISTINCT object_id) FROM sys.check_constraints cc
        JOIN sys.tables t ON cc.parent_object_id = t.object_id
        WHERE t.is_ms_shipped = 0 AND t.type = ''U'';

        SET @Pct = CASE WHEN @TotalTables = 0 THEN 100.0 ELSE (@TablesWithCC * 100.0) / @TotalTables END;

        IF @TotalTables = 0
        BEGIN
            SET @FindingText = ''No user tables found.'';
        END
        ELSE
        BEGIN
            SELECT @FindingText = STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name), '', '')
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.is_ms_shipped = 0 AND t.type = ''U''
              AND t.object_id NOT IN (SELECT DISTINCT parent_object_id FROM sys.check_constraints);

            IF @FindingText IS NULL SET @FindingText = ''No tables without check constraints.'';
            SET @FindingText = CAST(@Pct AS NVARCHAR(10)) + ''% coverage. Tables without check constraints: '' + @FindingText;
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + @DbName + ''', 
                CASE 
                    WHEN @TotalTables = 0 THEN 3
                    WHEN @Pct >= 80 THEN 3
                    WHEN @Pct >= 20 THEN 2
                    WHEN @Pct > 0 THEN 1
                    ELSE 0 
                END,
                @FindingText);
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE -- SQL Server / Azure SQL MI
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
            DECLARE @TotalTables INT;
            DECLARE @TablesWithCC INT;
            DECLARE @Pct FLOAT;
            DECLARE @FindingText NVARCHAR(MAX);

            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND type = ''U'';
            SELECT @TablesWithCC = COUNT(DISTINCT object_id) FROM sys.check_constraints cc
            JOIN sys.tables t ON cc.parent_object_id = t.object_id
            WHERE t.is_ms_shipped = 0 AND t.type = ''U'';

            SET @Pct = CASE WHEN @TotalTables = 0 THEN 100.0 ELSE (@TablesWithCC * 100.0) / @TotalTables END;

            IF @TotalTables = 0
            BEGIN
                SET @FindingText = ''No user tables found.'';
            END
            ELSE
            BEGIN
                SELECT @FindingText = STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name), '', '')
                FROM sys.tables t
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                WHERE t.is_ms_shipped = 0 AND t.type = ''U''
                  AND t.object_id NOT IN (SELECT DISTINCT parent_object_id FROM sys.check_constraints);

                IF @FindingText IS NULL SET @FindingText = ''No tables without check constraints.'';
                SET @FindingText = CAST(@Pct AS NVARCHAR(10)) + ''% coverage. Tables without check constraints: '' + @FindingText;
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', 
                    CASE 
                        WHEN @TotalTables = 0 THEN 3
                        WHEN @Pct >= 80 THEN 3
                        WHEN @Pct >= 20 THEN 2
                        WHEN @Pct > 0 THEN 1
                        ELSE 0 
                    END,
                    @FindingText);
            ';
            EXEC sp_executesql @Sql;
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