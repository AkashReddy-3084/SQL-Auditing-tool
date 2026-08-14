-- Checklist: Statistics kept current (auto-update on, plus manual updates after large loads)
-- Scope: DATABASE
-- Scoring: 0 = Auto-update stats OFF in any DB; 1 = Auto-update ON but >10% stats stale; 2 = Auto-update ON, <=10% stale; 3 = Auto-update ON, 0 stale (proxy for manual updates)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
-- NOTE: Requires SQL Server 2016+ for sys.dm_db_stats_properties
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;
DECLARE @AutoUpdateOn BIT;
DECLARE @TotalStats INT;
DECLARE @StaleStats INT;

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        -- Check auto-update stats setting
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @AutoUpdateOn = is_auto_update_stats_on FROM sys.databases WHERE name = DB_NAME();';
        EXEC sp_executesql @Sql, N'@AutoUpdateOn BIT OUTPUT', @AutoUpdateOn OUTPUT;

        IF @AutoUpdateOn = 0
        BEGIN
            INSERT INTO #DbResults VALUES (@DbName, 0);
        END
        ELSE
        BEGIN
            -- Check stats freshness using DMV (SQL 2016+)
            -- Fixed: Query sys.dm_db_stats_properties without parameters to avoid invalid TVF join syntax
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            SELECT @TotalStats = COUNT(*), 
                   @StaleStats = SUM(CASE WHEN modification_counter > 10000 AND DATEDIFF(day, last_updated, GETDATE()) > 3 THEN 1 ELSE 0 END)
            FROM sys.dm_db_stats_properties sp
            JOIN sys.stats s ON sp.object_id = s.object_id AND sp.stats_id = s.stats_id
            JOIN sys.tables t ON s.object_id = t.object_id;';
            EXEC sp_executesql @Sql, N'@TotalStats INT OUTPUT, @StaleStats INT OUTPUT', @TotalStats OUTPUT, @StaleStats OUTPUT;

            IF @TotalStats = 0
            BEGIN
                INSERT INTO #DbResults VALUES (@DbName, 3);
            END
            ELSE IF @StaleStats = 0
            BEGIN
                INSERT INTO #DbResults VALUES (@DbName, 3);
            END
            ELSE IF CAST(@StaleStats AS FLOAT) / @TotalStats <= 0.10
            BEGIN
                INSERT INTO #DbResults VALUES (@DbName, 2);
            END
            ELSE
            BEGIN
                INSERT INTO #DbResults VALUES (@DbName, 1);
            END
        END
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
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;