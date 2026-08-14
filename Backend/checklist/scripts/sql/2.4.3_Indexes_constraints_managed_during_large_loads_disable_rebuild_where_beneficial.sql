-- Checklist: Indexes/constraints managed during large loads (disable/rebuild where beneficial)
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Partial (<50% coverage), 2=Strong proxy (>=50% coverage), 3=Capped at 2 (proxy evidence)
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
        DECLARE @Total INT = 0, @Managed INT = 0;
        SELECT @Total = COUNT(*) FROM sys.procedures 
        WHERE name LIKE ''%load%'' OR name LIKE ''%etl%'' OR name LIKE ''%ingest%'' OR name LIKE ''%staging%'' OR name LIKE ''%bulk%'' OR name LIKE ''%import%'';
        
        SELECT @Managed = COUNT(*) FROM sys.procedures p 
        JOIN sys.sql_modules m ON p.object_id = m.object_id 
        WHERE (p.name LIKE ''%load%'' OR p.name LIKE ''%etl%'' OR p.name LIKE ''%ingest%'' OR p.name LIKE ''%staging%'' OR p.name LIKE ''%bulk%'' OR p.name LIKE ''%import%'')
          AND (m.definition LIKE ''%ALTER INDEX%'' OR m.definition LIKE ''%DISABLE%'' OR m.definition LIKE ''%REBUILD%'' OR m.definition LIKE ''%NOCHECK CONSTRAINT%'' OR m.definition LIKE ''%CHECK CONSTRAINT%'' OR m.definition LIKE ''%DROP INDEX%'' OR m.definition LIKE ''%CREATE INDEX%'');
          
        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + ', CASE WHEN @Total = 0 THEN 0 WHEN CAST(@Managed AS FLOAT)/@Total >= 0.5 THEN 2 WHEN @Managed > 0 THEN 1 ELSE 0 END);
        ';
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