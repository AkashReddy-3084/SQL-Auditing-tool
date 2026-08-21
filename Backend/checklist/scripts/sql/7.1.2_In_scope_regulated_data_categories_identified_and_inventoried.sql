-- Checklist: In-scope regulated data categories identified and inventoried
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=1-10 cols, 2=11-100 cols, 3=>100 cols. Proxy evidence caps at 2 if human review needed, but automated allows 3 for comprehensive coverage.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @DbScore INT;
DECLARE @DbFinding NVARCHAR(MAX);
DECLARE @ClassifiedCount INT;
DECLARE @MaskedCount INT;
DECLARE @TotalCols INT;

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
        SELECT @ClassifiedCount = COUNT(*)
        FROM sys.extended_properties ep
        JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id
        WHERE ep.name LIKE ''ms_%'';

        SELECT @MaskedCount = COUNT(*) FROM sys.masked_columns;

        SELECT @TotalCols = COUNT(*) FROM sys.columns;
    ';
    EXEC sp_executesql @Sql, N'@ClassifiedCount INT OUTPUT, @MaskedCount INT OUTPUT, @TotalCols INT OUTPUT',
        @ClassifiedCount OUTPUT, @MaskedCount OUTPUT, @TotalCols OUTPUT;

    SET @DbScore = CASE
        WHEN (@ClassifiedCount + @MaskedCount) = 0 THEN 0
        WHEN (@ClassifiedCount + @MaskedCount) BETWEEN 1 AND 10 THEN 1
        WHEN (@ClassifiedCount + @MaskedCount) BETWEEN 11 AND 100 THEN 2
        ELSE 3
    END;

    SET @DbFinding = N'Classified: ' + CAST(@ClassifiedCount AS NVARCHAR) + N', Masked: ' + CAST(@MaskedCount AS NVARCHAR) + N', Total Columns: ' + CAST(@TotalCols AS NVARCHAR);

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @DbFinding);
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
                SELECT @ClassifiedCount = COUNT(*)
                FROM sys.extended_properties ep
                JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id
                WHERE ep.name LIKE ''ms_%'';

                SELECT @MaskedCount = COUNT(*) FROM sys.masked_columns;

                SELECT @TotalCols = COUNT(*) FROM sys.columns;
            ';
            EXEC sp_executesql @Sql, N'@ClassifiedCount INT OUTPUT, @MaskedCount INT OUTPUT, @TotalCols INT OUTPUT',
                @ClassifiedCount OUTPUT, @MaskedCount OUTPUT, @TotalCols OUTPUT;

            SET @DbScore = CASE
                WHEN (@ClassifiedCount + @MaskedCount) = 0 THEN 0
                WHEN (@ClassifiedCount + @MaskedCount) BETWEEN 1 AND 10 THEN 1
                WHEN (@ClassifiedCount + @MaskedCount) BETWEEN 11 AND 100 THEN 2
                ELSE 3
            END;

            SET @DbFinding = N'Classified: ' + CAST(@ClassifiedCount AS NVARCHAR) + N', Masked: ' + CAST(@MaskedCount AS NVARCHAR) + N', Total Columns: ' + CAST(@TotalCols AS NVARCHAR);

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @DbFinding);
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, N'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @Finding = ISNULL(
    (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
IF @Score > 0
    SET @Finding = @Finding + N' -- NOTE: This script provides automated evidence. Full compliance requires human review.';

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;