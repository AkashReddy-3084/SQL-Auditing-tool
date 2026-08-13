-- Checklist: Star schema implemented (fact + dimension tables, not flat wide tables)
-- Scope: DATABASE
-- Scoring: 0=No fact/dim tables found; 1=1-2 fact/dim tables or missing FK relationships; 2=Strong proxy evidence (>=3 fact/dim tables with FKs); 3=Theoretical perfect match, but capped at 2 due to indirect/proxy nature of schema design verification
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
        DECLARE @FactDimCount INT = 0;
        DECLARE @FkCount INT = 0;

        SELECT @FactDimCount = COUNT(*) FROM sys.tables t
        WHERE t.name LIKE ''fact%'' OR t.name LIKE ''dim%'' OR t.name LIKE ''Fact%'' OR t.name LIKE ''Dim%'';

        SELECT @FkCount = COUNT(*) FROM sys.foreign_keys fk
        JOIN sys.tables t ON fk.parent_object_id = t.object_id
        WHERE t.name LIKE ''fact%'' OR t.name LIKE ''Fact%'';

        DECLARE @DbScore INT = 0;
        IF @FactDimCount = 0 SET @DbScore = 0;
        ELSE IF @FactDimCount <= 2 OR @FkCount = 0 SET @DbScore = 1;
        ELSE SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.