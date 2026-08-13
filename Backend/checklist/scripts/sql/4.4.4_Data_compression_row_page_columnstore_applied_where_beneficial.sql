-- Checklist: Data compression (row/page/columnstore) applied where beneficial
-- Scope: DATABASE
-- Scoring: 0=0% compressed, 1=1-24%, 2=25-74%, 3=>=75% of user table/index partitions have compression enabled. NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @Total INT = 0;
        DECLARE @Compressed INT = 0;
        SELECT @Total = COUNT(p.partition_id), @Compressed = SUM(CASE WHEN p.data_compression > 0 THEN 1 ELSE 0 END)
        FROM sys.partitions p
        JOIN sys.indexes i ON p.object_id = i.object_id AND p.index_id = i.index_id
        JOIN sys.tables t ON i.object_id = t.object_id
        WHERE t.is_ms_shipped = 0;

        DECLARE @DbScore INT = 0;
        IF @Total = 0 SET @DbScore = 3;
        ELSE BEGIN
            DECLARE @Pct FLOAT = (@Compressed * 100.0) / @Total;
            SET @DbScore = CASE
                WHEN @Pct >= 75 THEN 3
                WHEN @Pct >= 25 THEN 2
                WHEN @Pct >= 1 THEN 1
                ELSE 0
            END;
        END;
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