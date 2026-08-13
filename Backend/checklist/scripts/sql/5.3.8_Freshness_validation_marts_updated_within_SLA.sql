-- Checklist: Freshness validation: marts updated within SLA
-- Scope: DATABASE
-- Scoring: 0=No recent updates (>48h or no tables), 1=Partial freshness (1-69% tables updated within 24h), 2=Mostly fresh (70-100% tables updated within 24h), 3=Fully compliant (all tables fresh within exact SLA). Max score capped at 2 because actual SLA compliance requires human validation of business thresholds; script uses 24h proxy evidence.
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
        DECLARE @TotalTables INT = 0;
        DECLARE @FreshTables INT = 0;
        DECLARE @ThresholdHours INT = 24;
        DECLARE @DbScore INT = 0;

        SELECT @TotalTables = COUNT(*)
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE s.name LIKE ''%mart%'' OR s.name LIKE ''%dw%'' OR s.name LIKE ''%data%'';

        IF @TotalTables > 0
        BEGIN
            SELECT @FreshTables = COUNT(*)
            FROM (
                SELECT t.object_id, 
                       ISNULL(MAX(i.stats_modified_date), t.modify_date) AS last_update
                FROM sys.tables t
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                LEFT JOIN sys.indexes i ON t.object_id = i.object_id AND i.type <= 1
                WHERE (s.name LIKE ''%mart%'' OR s.name LIKE ''%dw%'' OR s.name LIKE ''%data%'')
                GROUP BY t.object_id, t.modify_date
            ) AS tbl
            WHERE DATEDIFF(hour, last_update, GETDATE()) <= @ThresholdHours;

            IF @FreshTables = 0 SET @DbScore = 0;
            ELSE IF CAST(@FreshTables AS FLOAT) / @TotalTables < 0.7 SET @DbScore = 1;
            ELSE SET @DbScore = 2;
        END
        ELSE
        BEGIN
            SET @DbScore = 0;
        END

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
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