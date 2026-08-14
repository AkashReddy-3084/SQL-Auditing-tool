-- Checklist: Fill factor tuned for volatile tables where needed
-- Scope: DATABASE
-- Scoring: 0=No tuning on volatile tables, 1=1-49% tuned, 2=50-99% tuned, 3=100% tuned. Volatility proxied by user_updates > 1000.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @VolatileCount INT = 0;
        DECLARE @TunedCount INT = 0;

        SELECT @VolatileCount = COUNT(DISTINCT i.index_id)
        FROM sys.indexes i
        JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id
        WHERE us.database_id = DB_ID() AND us.user_updates > 1000 AND i.index_id > 0;

        SELECT @TunedCount = COUNT(DISTINCT i.index_id)
        FROM sys.indexes i
        JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id
        WHERE us.database_id = DB_ID() AND us.user_updates > 1000 AND i.fill_factor < 100 AND i.index_id > 0;

        DECLARE @DbScore INT = 0;
        IF @VolatileCount = 0
            SET @DbScore = 2; -- Capped at 2 per guidelines
        ELSE
        BEGIN
            DECLARE @Pct FLOAT = CAST(@TunedCount AS FLOAT) / CAST(@VolatileCount AS FLOAT);
            SET @DbScore = CASE
                WHEN @Pct >= 0.5 THEN 2
                WHEN @Pct > 0.0 THEN 1
                ELSE 0
            END;
        END;
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

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
-- Enforce max score cap of 2 per guidelines
SET @Score = CASE WHEN @Score > 2 THEN 2 ELSE @Score END;
SET @Result = CASE WHEN @Score >= 2 THEN ''Pass'' ELSE ''Fail'' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;