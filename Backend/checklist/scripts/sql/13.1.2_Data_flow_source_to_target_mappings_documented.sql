-- Checklist: Data flow / source-to-target mappings documented
-- Scope: DATABASE
-- Scoring: 0 = No evidence found. 1 = Minimal evidence (1-5 artifacts). 2 = Moderate evidence (6-20 artifacts). 3 = Comprehensive evidence (>20 artifacts).
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
        DECLARE @PropCount INT = 0;
        DECLARE @MapTableCount INT = 0;
        
        SELECT @PropCount = COUNT(*) FROM sys.extended_properties WHERE class = 1;
        
        SELECT @MapTableCount = COUNT(*) FROM sys.tables 
        WHERE name LIKE ''%Mapping%'' OR name LIKE ''%Source%'' OR name LIKE ''%Target%'' OR name LIKE ''%Flow%'';
        
        DECLARE @Total INT = @PropCount + @MapTableCount;
        DECLARE @DbScore INT = 0;
        
        IF @Total = 0 SET @DbScore = 0;
        ELSE IF @Total <= 5 SET @DbScore = 1;
        ELSE IF @Total <= 20 SET @DbScore = 2;
        ELSE SET @DbScore = 3;
        
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