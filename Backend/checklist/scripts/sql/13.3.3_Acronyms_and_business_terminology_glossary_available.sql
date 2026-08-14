-- Checklist: Acronyms and business terminology glossary available
-- Scope: DATABASE
-- Scoring: 0=No evidence; 1=Minimal evidence; 2=Good evidence; Capped at 2 (proxy evidence)
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
        INSERT INTO #DbResults (DbName, DbScore)
        SELECT ' + QUOTENAME(@DbName, '''') + N',
               CASE
                   WHEN (SELECT COUNT(*) FROM sys.extended_properties WHERE class = 1 AND name LIKE ''%definition%'' OR name LIKE ''%glossary%'' OR name LIKE ''%description%'' OR name LIKE ''%business_term%'') > 10
                     OR EXISTS (SELECT 1 FROM sys.tables t JOIN sys.partitions p ON t.object_id = p.object_id WHERE t.name LIKE ''%Glossary%'' OR t.name LIKE ''%Dictionary%'' OR t.name LIKE ''%Terminology%'' AND p.rows > 0)
                   THEN 2
                   WHEN (SELECT COUNT(*) FROM sys.extended_properties WHERE class = 1 AND name LIKE ''%definition%'' OR name LIKE ''%glossary%'' OR name LIKE ''%description%'' OR name LIKE ''%business_term%'') > 0
                     OR EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE ''%Glossary%'' OR name LIKE ''%Dictionary%'' OR name LIKE ''%Terminology%'')
                   THEN 1
                   ELSE 0
               END;';
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