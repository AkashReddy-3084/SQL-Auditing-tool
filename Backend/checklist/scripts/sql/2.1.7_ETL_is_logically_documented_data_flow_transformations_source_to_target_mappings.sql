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
        DECLARE @TotalObjects INT;
        DECLARE @DocumentedObjects INT;
        DECLARE @HasMappingTable BIT = 0;

        SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'', ''P'') AND is_ms_shipped = 0;
        SELECT @DocumentedObjects = COUNT(DISTINCT major_id) FROM sys.extended_properties WHERE class = 1 AND name = ''MS_Description'' AND major_id IN (SELECT object_id FROM sys.objects WHERE type IN (''U'', ''P'') AND is_ms_shipped = 0);
        IF EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE ''%map%'' OR name LIKE ''%metadata%'' OR name LIKE ''%control%'' OR name LIKE ''%config%'') SET @HasMappingTable = 1;

        DECLARE @Coverage DECIMAL(5,2);
        SET @Coverage = CASE WHEN @TotalObjects > 0 THEN (@DocumentedObjects * 100.0 / @TotalObjects) ELSE 0 END;
        DECLARE @DbScore INT = 0;

        IF @Coverage >= 30 OR @HasMappingTable = 1 SET @DbScore = 2;
        ELSE IF @Coverage > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
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