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
        SELECT 
            DB_NAME() AS DbName,
            CASE 
                WHEN EXISTS (SELECT 1 FROM sys.database_encryption_keys WHERE encryption_state = 3 AND encryptor_type = ''EK'') THEN 3
                WHEN EXISTS (SELECT 1 FROM sys.database_encryption_keys WHERE encryptor_type = ''EK'' AND encryption_state IN (2, 6)) THEN 2
                WHEN EXISTS (SELECT 1 FROM sys.database_encryption_keys WHERE encryption_state = 3 AND encryptor_type = ''KM'') THEN 1
                ELSE 0
            END AS DbScore;';
        INSERT INTO #DbResults
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score = 3 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;