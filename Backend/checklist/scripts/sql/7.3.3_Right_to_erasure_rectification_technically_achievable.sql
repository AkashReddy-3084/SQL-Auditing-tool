DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

IF OBJECT_ID('sys.databases') IS NOT NULL
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @DbScore = 0;
        BEGIN TRY
            SET @Sql = N'
                DECLARE @TotalTables INT, @TablesWithPK INT, @SoftDeleteCols INT, @PartitionedTables INT, @ErasureProcs INT;
                SELECT @TotalTables = COUNT(*) FROM ' + QUOTENAME(@DbName) + '.sys.tables WHERE type = ''U'';
                SELECT @TablesWithPK = COUNT(*) FROM ' + QUOTENAME(@DbName) + '.sys.tables t JOIN ' + QUOTENAME(@DbName) + '.sys.indexes i ON t.object_id = i.object_id AND i.is_primary_key = 1 WHERE t.type = ''U'';
                SELECT @SoftDeleteCols = COUNT(*) FROM ' + QUOTENAME(@DbName) + '.sys.columns c JOIN ' + QUOTENAME(@DbName) + '.sys.tables t ON c.object_id = t.object_id WHERE t.type = ''U'' AND (c.name LIKE ''%deleted%'' OR c.name LIKE ''%is_active%'' OR c.name LIKE ''%status%'');
                SELECT @PartitionedTables = COUNT(DISTINCT object_id) FROM ' + QUOTENAME(@DbName) + '.sys.partitions p JOIN ' + QUOTENAME(@DbName) + '.sys.tables t ON p.object_id = t.object_id WHERE t.type = ''U'' AND p.partition_number > 1;
                SELECT @ErasureProcs = COUNT(*) FROM ' + QUOTENAME(@DbName) + '.sys.procedures WHERE name LIKE ''%Delete%'' OR name LIKE ''%Erase%'' OR name LIKE ''%Retention%'' OR name LIKE ''%Privacy%'';

                SET @DbScore = 0;
                IF @TotalTables > 0
                BEGIN
                    IF CAST(@TablesWithPK AS FLOAT) / @TotalTables >= 0.5 SET @DbScore += 1;
                    IF @SoftDeleteCols > 0 OR @PartitionedTables > 0 SET @DbScore += 1;
                    IF @ErasureProcs > 0 SET @DbScore += 1;
                END
                SET @DbScore = CASE WHEN @DbScore > 2 THEN 2 ELSE @DbScore END;
            ';
            EXEC sp_executesql @Sql, N'@DbScore INT OUTPUT', @DbScore OUTPUT;
        END TRY
        BEGIN CATCH
            SET @DbScore = 0;
        END CATCH;
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        FETCH NEXT FROM db_cursor INTO @DbName;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END
ELSE
BEGIN
    -- Fallback for environments where sys.databases is restricted
    SET @DbName = DB_NAME();
    SET @DbScore = 0;
    BEGIN TRY
        SET @Sql = N'
            DECLARE @TotalTables INT, @TablesWithPK INT, @SoftDeleteCols INT, @PartitionedTables INT, @ErasureProcs INT;
            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
            SELECT @TablesWithPK = COUNT(*) FROM sys.tables t JOIN sys.indexes i ON t.object_id = i.object_id AND i.is_primary_key = 1 WHERE t.type = ''U'';
            SELECT @SoftDeleteCols = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.type = ''U'' AND (c.name LIKE ''%deleted%'' OR c.name LIKE ''%is_active%'' OR c.name LIKE ''%status%'');
            SELECT @PartitionedTables = COUNT(DISTINCT object_id) FROM sys.partitions p JOIN sys.tables t ON p.object_id = t.object_id WHERE t.type = ''U'' AND p.partition_number > 1;
            SELECT @ErasureProcs = COUNT(*) FROM sys.procedures WHERE name LIKE ''%Delete%'' OR name LIKE ''%Erase%'' OR name LIKE ''%Retention%'' OR name LIKE ''%Privacy%'';

            SET @DbScore = 0;
            IF @TotalTables > 0
            BEGIN
                IF CAST(@TablesWithPK AS FLOAT) / @TotalTables >= 0.5 SET @DbScore += 1;
                IF @SoftDeleteCols > 0 OR @PartitionedTables > 0 SET @DbScore += 1;
                IF @ErasureProcs > 0 SET @DbScore += 1;
            END
            SET @DbScore = CASE WHEN @DbScore > 2 THEN 2 ELSE @DbScore END;
        ';
        EXEC sp_executesql @Sql, N'@DbScore INT OUTPUT', @DbScore OUTPUT;
    END TRY
    BEGIN CATCH
        SET @DbScore = 0;
    END CATCH;
    INSERT INTO #DbResults VALUES (@DbName, @DbScore);
END

-- Aggregate results: worst-case (MIN) across all evaluated databases
SELECT @Score = ISNULL(MIN(DbScore), 0) FROM #DbResults;

-- Determine Pass/Fail based on score
SET @Result = CASE WHEN @Score > 0 THEN 'Pass' ELSE 'Fail' END;

-- Required output format
SELECT @Result AS Result, @Score AS Score;

-- Cleanup
DROP TABLE #DbResults;