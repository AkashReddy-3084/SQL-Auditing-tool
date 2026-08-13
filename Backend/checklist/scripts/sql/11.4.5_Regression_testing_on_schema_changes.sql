-- Checklist: Regression testing on schema changes
-- Scope: DATABASE
-- Scoring: 0 = No test artifacts found; 1 = Minimal evidence (1-4 test procedures/properties/schemas); 2 = Strong proxy evidence (5+ test artifacts or dedicated test framework detected); NOTE: Max score capped at 2 as this relies on indirect evidence.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @TestCount INT;

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
        SELECT @TestCount = COUNT(*) FROM (
            SELECT object_id FROM sys.objects WHERE type IN (''P'',''V'',''FN'') AND (name LIKE ''test_%'' OR name LIKE ''spec_%'' OR name LIKE ''regression_%'')
            UNION
            SELECT major_id FROM sys.extended_properties WHERE name LIKE ''%test%'' OR name LIKE ''%coverage%'' OR name LIKE ''%regression%''
            UNION
            SELECT schema_id FROM sys.schemas WHERE name IN (''test'',''spec'',''regression'',''tdd'')
        ) AS TestArtifacts;
        ';
        EXEC sp_executesql @Sql, N'@TestCount INT OUTPUT', @TestCount OUTPUT;
        
        IF @TestCount >= 5 SET @TestCount = 2;
        ELSE IF @TestCount >= 1 SET @TestCount = 1;
        ELSE SET @TestCount = 0;
        
        INSERT INTO #DbResults VALUES (@DbName, @TestCount);
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.