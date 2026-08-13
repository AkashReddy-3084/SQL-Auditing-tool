-- Checklist: Escalation path for data quality issues defined
-- Scope: DATABASE
-- Scoring: 0 = No evidence found; 1 = Sparse mentions in comments/properties; 2 = Clear mentions of escalation/DQ contacts in metadata; 3 = Not achievable (proxy evidence only)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @Matches INT = 0;
        SELECT @Matches = COUNT(*) FROM sys.extended_properties
        WHERE value IS NOT NULL AND (CAST(value AS NVARCHAR(4000)) LIKE ''%escalation%'' OR CAST(value AS NVARCHAR(4000)) LIKE ''%data quality%'' OR CAST(value AS NVARCHAR(4000)) LIKE ''%DQ%'' OR CAST(value AS NVARCHAR(4000)) LIKE ''%contact%'');
        SET @Matches = @Matches + (SELECT COUNT(*) FROM sys.sql_modules
        WHERE definition IS NOT NULL AND (definition LIKE ''%escalation%'' OR definition LIKE ''%data quality%'' OR definition LIKE ''%DQ%'' OR definition LIKE ''%contact%''));
        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + ', CASE WHEN @Matches > 5 THEN 2 WHEN @Matches > 0 THEN 1 ELSE 0 END);';
        EXEC sp_executesql @Sql;
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.