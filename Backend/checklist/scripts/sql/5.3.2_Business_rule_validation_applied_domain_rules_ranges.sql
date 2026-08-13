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
        DECLARE @ConstraintCount INT = 0;
        SELECT @ConstraintCount = COUNT(*) FROM sys.check_constraints;
        SELECT @ConstraintCount = @ConstraintCount + COUNT(*) FROM sys.default_constraints;
        
        DECLARE @DbScore INT = 0;
        IF @ConstraintCount = 0 SET @DbScore = 0;
        ELSE IF @ConstraintCount <= 10 SET @DbScore = 1;
        ELSE IF @ConstraintCount <= 50 SET @DbScore = 2;
        ELSE SET @DbScore = 3;
        
        IF @DbScore > 2 SET @DbScore = 2;
        
        INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
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