-- Checklist: Unit tests exist for critical transformation logic (e.g., tSQLt)
-- Scope: DATABASE
-- Scoring: 0=No test framework/tests found, 1=tSQLt schema exists but no test procedures, 2=tSQLt installed with 1-5 test procedures, 3=tSQLt installed with >5 test procedures
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
-- Create temp table to collect per-database results
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
        DECLARE @tSQLtSchemaId INT = (SELECT schema_id FROM sys.schemas WHERE name = ''tSQLt'');
        DECLARE @TestCount INT = 0;
        IF @tSQLtSchemaId IS NOT NULL
        BEGIN
            SELECT @TestCount = COUNT(*) FROM sys.procedures p
            WHERE p.schema_id = @tSQLtSchemaId AND (p.name LIKE ''%Test%'' OR p.name LIKE ''%Spec%'');
        END;
        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', CASE 
            WHEN @tSQLtSchemaId IS NULL THEN 0
            WHEN @TestCount = 0 THEN 1
            WHEN @TestCount BETWEEN 1 AND 5 THEN 2
            ELSE 3
        END);';
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