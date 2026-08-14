-- Checklist: Source-to-target mapping documented per table
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=1-25% tables documented, 2=26-99% documented, 3=100% documented
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
        DECLARE @TotalTables INT;
        DECLARE @MappedTables INT;
        SELECT @TotalTables = COUNT(*) FROM sys.tables;
        SELECT @MappedTables = COUNT(DISTINCT major_id) FROM sys.extended_properties
        WHERE class = 1 AND minor_id = 0 AND (name LIKE ''%mapping%'' OR name LIKE ''%source%'' OR name LIKE ''%target%'' OR name LIKE ''%description%'');
        INSERT INTO #DbResults VALUES (@DbName, CASE
            WHEN @TotalTables = 0 THEN 3
            WHEN @MappedTables = 0 THEN 0
            WHEN CAST(@MappedTables AS FLOAT) / @TotalTables <= 0.25 THEN 1
            WHEN CAST(@MappedTables AS FLOAT) / @TotalTables < 1.0 THEN 2
            ELSE 3
        END);';
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