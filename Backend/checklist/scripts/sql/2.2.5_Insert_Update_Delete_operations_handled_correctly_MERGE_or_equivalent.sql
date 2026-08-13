-- Checklist: Insert/Update/Delete operations handled correctly (MERGE or equivalent)
-- Scope: DATABASE
-- Scoring: 0=No I/U/D logic found, 1=Only partial (INSERT/UPDATE), 2=MERGE or equivalent I/U/D found, 3=Comprehensive I/U/D or MERGE with OUTPUT found consistently
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
        DECLARE @TotalProcs INT = 0;
        DECLARE @MergeProcs INT = 0;
        DECLARE @IUDProcs INT = 0;
        DECLARE @FullIUDProcs INT = 0;

        SELECT @TotalProcs = COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0;
        SELECT @MergeProcs = COUNT(*) FROM sys.sql_modules m JOIN sys.procedures p ON m.object_id = p.object_id
        WHERE p.is_ms_shipped = 0 AND m.definition IS NOT NULL AND OBJECT_DEFINITION(m.object_id) LIKE ''%MERGE%'';
        SELECT @IUDProcs = COUNT(*) FROM sys.sql_modules m JOIN sys.procedures p ON m.object_id = p.object_id
        WHERE p.is_ms_shipped = 0 AND m.definition IS NOT NULL AND OBJECT_DEFINITION(m.object_id) LIKE ''%INSERT%'' AND OBJECT_DEFINITION(m.object_id) LIKE ''%UPDATE%'';
        SELECT @FullIUDProcs = COUNT(*) FROM sys.sql_modules m JOIN sys.procedures p ON m.object_id = p.object_id
        WHERE p.is_ms_shipped = 0 AND m.definition IS NOT NULL AND OBJECT_DEFINITION(m.object_id) LIKE ''%INSERT%'' AND OBJECT_DEFINITION(m.object_id) LIKE ''%UPDATE%'' AND OBJECT_DEFINITION(m.object_id) LIKE ''%DELETE%'';

        DECLARE @DbScore INT = 0;
        IF @TotalProcs > 0
        BEGIN
            IF @FullIUDProcs > 0 SET @DbScore = 3;
            ELSE IF @MergeProcs > 0 SET @DbScore = 2;
            ELSE IF @IUDProcs > 0 SET @DbScore = 1;
        END
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        ';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;