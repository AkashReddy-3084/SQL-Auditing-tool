-- Checklist: Unknown/default dimension member usage monitored
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Dim tables exist but no monitoring, 2=Monitoring artifacts/columns/properties found, 3=Reserved for full runtime verification
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
DECLARE @DimCount INT = 0, @MonObjCount INT = 0, @MonColCount INT = 0, @ExtPropCount INT = 0;
SELECT @DimCount = COUNT(*) FROM sys.tables WHERE name LIKE ''dim_%'' OR name LIKE ''%dimension%'';
SELECT @MonObjCount = COUNT(*) FROM sys.objects WHERE type IN (''P'',''V'') AND (name LIKE ''%monitor%'' OR name LIKE ''%audit%'' OR name LIKE ''%unknown%'' OR name LIKE ''%default%'');
SELECT @MonColCount = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE (t.name LIKE ''dim_%'' OR t.name LIKE ''%dimension%'') AND (c.name LIKE ''%unknown%'' OR c.name LIKE ''%default%'' OR c.name LIKE ''%flag%'' OR c.name LIKE ''%status%'');
SELECT @ExtPropCount = COUNT(*) FROM sys.extended_properties WHERE value LIKE ''%unknown%'' OR value LIKE ''%default%'';
INSERT INTO #DbResults VALUES (''' + @DbName + ''', CASE WHEN @DimCount = 0 AND @MonObjCount = 0 AND @MonColCount = 0 AND @ExtPropCount = 0 THEN 0 WHEN @DimCount > 0 AND @MonObjCount = 0 AND @MonColCount = 0 AND @ExtPropCount = 0 THEN 1 WHEN @MonObjCount > 0 OR @MonColCount > 0 OR @ExtPropCount > 0 THEN 2 END);';
        EXEC(@Sql);
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