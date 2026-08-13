-- Checklist: Schemas used to organize objects by layer/domain
-- Scope: DATABASE
-- Scoring: 0=All objects in dbo, 1=1-49% in non-dbo, 2=50-89% in non-dbo, 3=>=90% in non-dbo
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
DECLARE @NonDboObjects INT;
DECLARE @LocalScore INT = 0;

SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'',''V'',''P'',''IF'',''FN'',''TF'');
SELECT @NonDboObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'',''V'',''P'',''IF'',''FN'',''TF'') AND schema_id <> 1;

IF @TotalObjects = 0 SET @LocalScore = 0;
ELSE BEGIN
    DECLARE @Pct FLOAT = (@NonDboObjects * 100.0) / @TotalObjects;
    IF @Pct >= 90 SET @LocalScore = 3;
    ELSE IF @Pct >= 50 SET @LocalScore = 2;
    ELSE IF @Pct >= 1 SET @LocalScore = 1;
    ELSE SET @LocalScore = 0;
END;

SELECT @DbName AS DbName, @LocalScore AS DbScore;
';
        INSERT INTO #DbResults (DbName, DbScore) EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
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