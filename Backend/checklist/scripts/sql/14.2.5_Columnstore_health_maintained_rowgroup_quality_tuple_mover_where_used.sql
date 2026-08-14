-- Checklist: Columnstore health maintained (rowgroup quality, tuple mover) where used
-- Scope: DATABASE
-- Scoring: 0=<50% compressed, 1=50-80%, 2=80-95%, 3=>=95% or not used
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
        DECLARE @TotalRowgroups INT = 0;
        DECLARE @CompressedRowgroups INT = 0;
        DECLARE @HasColumnstore BIT = 0;
        DECLARE @DbScore INT = 3;

        SELECT @HasColumnstore = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
        FROM sys.indexes WHERE type IN (5, 6);

        IF @HasColumnstore = 1 AND OBJECT_ID('sys.dm_db_column_store_row_group_physical_stats') IS NOT NULL
        BEGIN
            SELECT @TotalRowgroups = COUNT(*),
                   @CompressedRowgroups = SUM(CASE WHEN state = 2 THEN 1 ELSE 0 END)
            FROM sys.dm_db_column_store_row_group_physical_stats;

            IF @TotalRowgroups > 0
            BEGIN
                DECLARE @Ratio FLOAT = CAST(@CompressedRowgroups AS FLOAT) / @TotalRowgroups;
                IF @Ratio >= 0.95 SET @DbScore = 3;
                ELSE IF @Ratio >= 0.80 SET @DbScore = 2;
                ELSE IF @Ratio >= 0.50 SET @DbScore = 1;
                ELSE SET @DbScore = 0;
            END
        END
        ELSE IF @HasColumnstore = 1 AND OBJECT_ID('sys.dm_db_column_store_row_group_physical_stats') IS NULL
        BEGIN
            SET @DbScore = 1; -- DMV unavailable, partial evidence only
        END

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        ';
        EXEC(@Sql);
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 3);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;