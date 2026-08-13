-- Checklist: Temp tables vs table variables chosen appropriately for cardinality
-- Scope: DATABASE
-- Scoring: 0=No programmability objects found; 1=Heavy table variable usage without mitigation; 2=Mixed usage with partial mitigation or temp tables preferred; 3=Best practices fully verified (requires human review of actual cardinality).
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @TableVarCount INT = 0;
        DECLARE @TempTableCount INT = 0;
        DECLARE @MitigatedCount INT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @TableVarCount = COUNT(*) FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE m.definition LIKE ''%DECLARE @%TABLE%'';

        SELECT @TempTableCount = COUNT(*) FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE m.definition LIKE ''%CREATE TABLE #%'';

        SELECT @MitigatedCount = COUNT(*) FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE m.definition LIKE ''%DECLARE @%TABLE%''
        AND m.definition LIKE ''%OPTION (RECOMPILE)%'';

        IF @TableVarCount = 0 AND @TempTableCount = 0 SET @DbScore = 0;
        ELSE IF @TableVarCount > 0 AND @MitigatedCount = 0 SET @DbScore = 1;
        ELSE IF @TableVarCount > 0 AND @MitigatedCount < @TableVarCount SET @DbScore = 2;
        ELSE SET @DbScore = 2; -- Capped at 2 for proxy evidence

        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore);';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;