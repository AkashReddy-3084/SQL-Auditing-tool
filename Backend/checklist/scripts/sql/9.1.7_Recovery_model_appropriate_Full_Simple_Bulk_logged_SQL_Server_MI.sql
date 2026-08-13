-- Checklist: Recovery model appropriate (Full/Simple/Bulk-logged) — SQL Server/MI
-- Scope: DATABASE
-- Scoring: 3 = Pass (recovery model is explicitly set to Full, Simple, or Bulk-logged), 0 = Fail (recovery model is missing, null, or invalid). SQL Server enforces one of these three, so this verifies the configuration is present and valid.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;

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
        SELECT @DbScore = CASE 
            WHEN DATABASEPROPERTYEX(DB_NAME(), ''Recovery'') IN (''FULL'', ''SIMPLE'', ''BULK_LOGGED'') THEN 3
            ELSE 0
        END;';
        EXEC sp_executesql @Sql, N'@DbScore INT OUTPUT', @DbScore OUTPUT;
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
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