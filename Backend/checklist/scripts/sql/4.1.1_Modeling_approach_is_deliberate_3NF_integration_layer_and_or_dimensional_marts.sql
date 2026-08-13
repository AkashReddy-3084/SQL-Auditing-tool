-- Checklist: Modeling approach is deliberate (3NF integration layer and/or dimensional marts)
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Minimal, 2=Strong proxy, 3=Exceptional proxy
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
DECLARE @DimFactCount INT, @FKCount INT, @NonDboTableCount INT;

SELECT @DimFactCount = COUNT(*) 
FROM sys.tables t 
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE t.name LIKE ''dim[_]%'' OR t.name LIKE ''fact[_]%'' OR t.name LIKE ''stg[_]%'' OR t.name LIKE ''ods[_]%'' OR t.name LIKE ''dw[_]%''
   OR s.name LIKE ''dim[_]%'' OR s.name LIKE ''fact[_]%'' OR s.name LIKE ''stg[_]%'' OR s.name LIKE ''ods[_]%'' OR s.name LIKE ''dw[_]%'';

SELECT @FKCount = COUNT(*) FROM sys.foreign_keys;

SELECT @NonDboTableCount = COUNT(*) 
FROM sys.tables t 
JOIN sys.schemas s ON t.schema_id = s.schema_id 
WHERE s.name <> ''dbo'';

DECLARE @DbScore INT = 0;
-- Evaluate from highest to lowest to ensure correct precedence
IF @DimFactCount >= 10 AND @FKCount >= 20 AND @NonDboTableCount >= 5 SET @DbScore = 3;
ELSE IF @DimFactCount >= 5 OR @FKCount >= 10 OR @NonDboTableCount > 0 SET @DbScore = 2;
ELSE IF @DimFactCount >= 1 OR @FKCount >= 1 SET @DbScore = 1;
ELSE SET @DbScore = 0;

INSERT INTO #DbResults (DbName, DbScore) VALUES (@DbNameParam, @DbScore);';
        
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore) VALUES (@DbName, 0);
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