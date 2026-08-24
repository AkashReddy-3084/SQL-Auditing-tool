DECLARE @Result VARCHAR(50);
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried VARCHAR(128) = 'master';
DECLARE @Finding VARCHAR(MAX) = 'No data compression applied.';
DECLARE @TotalCompressed INT = 0;

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SELECT @TotalCompressed = COUNT(*) FROM sys.partitions WHERE data_compression > 0;
END
ELSE
BEGIN
    IF OBJECT_ID('tempdb..#Comp') IS NOT NULL DROP TABLE #Comp;
    CREATE TABLE #Comp (CompressedPartitions INT);
    
    DECLARE @Db sysname;
    DECLARE @SQL NVARCHAR(MAX);
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;
    
    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @Db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @SQL = N'INSERT INTO #Comp (CompressedPartitions) SELECT COUNT(*) FROM ' + QUOTENAME(@Db) + N'.sys.partitions WHERE data_compression > 0;';
        BEGIN TRY
            EXEC sp_executesql @SQL;
        END TRY
        BEGIN CATCH
        END CATCH
        FETCH NEXT FROM db_cursor INTO @Db;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;
    
    SELECT @TotalCompressed = SUM(CompressedPartitions) FROM #Comp;
END

IF ISNULL(@TotalCompressed, 0) > 0
BEGIN
    SET @Score = 3;
    SET @Finding = CAST(@TotalCompressed AS VARCHAR(20)) + ' compressed partitions found.';
END
ELSE
BEGIN
    SET @Score = 1;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT 
    @Result AS Result, 
    @Score AS Score, 
    @DatabaseQueried AS DatabaseQueried, 
    @Finding AS Finding;