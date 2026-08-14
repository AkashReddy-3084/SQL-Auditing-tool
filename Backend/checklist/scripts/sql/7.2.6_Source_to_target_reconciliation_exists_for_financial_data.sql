-- Checklist: Source-to-target reconciliation exists for financial data
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Minimal evidence (1-5 objects with weak matches), 2=Good evidence (6+ objects or definitions contain reconciliation logic), 3=Strong evidence (dedicated recon schema/control tables + automated variance procedures)
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
        DECLARE @ObjCount INT = 0;
        DECLARE @DefCount INT = 0;
        DECLARE @SchCount INT = 0;

        SELECT @ObjCount = COUNT(*) FROM sys.objects 
        WHERE type IN (''U'',''P'',''V'',''FN'') 
        AND (name LIKE ''%recon%'' OR name LIKE ''%reconcil%'' OR name LIKE ''%financial%'' OR name LIKE ''%ledger%'' OR name LIKE ''%balance%'' OR name LIKE ''%variance%'' OR name LIKE ''%control%'' OR name LIKE ''%sox%'' OR name LIKE ''%itgc%'');

        SELECT @DefCount = COUNT(*) FROM sys.sql_modules m 
        JOIN sys.objects o ON m.object_id = o.object_id 
        WHERE o.type IN (''P'',''FN'',''V'') 
        AND (m.definition LIKE ''%reconcil%'' OR m.definition LIKE ''%variance%'' OR m.definition LIKE ''%control total%'' OR m.definition LIKE ''%difference%'' OR m.definition LIKE ''%source%target%'');

        SELECT @SchCount = COUNT(*) FROM sys.schemas 
        WHERE name LIKE ''%recon%'' OR name LIKE ''%control%'' OR name LIKE ''%audit%'';

        INSERT INTO #DbResults VALUES (@DbName, CASE 
            WHEN @ObjCount = 0 AND @DefCount = 0 THEN 0 
            WHEN @ObjCount BETWEEN 1 AND 5 AND @DefCount = 0 THEN 1 
            WHEN @SchCount >= 1 AND @DefCount >= 2 THEN 3 
            WHEN @ObjCount >= 6 OR @DefCount >= 1 THEN 2 
            ELSE 1 
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