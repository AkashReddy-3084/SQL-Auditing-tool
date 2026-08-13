-- Checklist: Data freshness SLAs defined per mart/data product
-- Scope: DATABASE
-- Scoring: 0=No freshness metadata/tracking found; 1=Partial evidence (some tables have timestamp columns or SLA extended properties); 2=Mostly Pass (>=50% of tables have explicit SLA/freshness metadata or consistent timestamp tracking); 3=Pass (>=80% of tables have explicit SLA/freshness extended properties combined with timestamp columns)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
-- Create temp table to collect per-database results
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
        DECLARE @DbScore INT = 0;
        DECLARE @TotalTables INT = 0;
        DECLARE @TablesWithSLA INT = 0;
        DECLARE @TablesWithTimestamp INT = 0;

        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';

        SELECT @TablesWithSLA = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
        WHERE ep.name LIKE ''%sla%'' OR ep.name LIKE ''%freshness%'' OR ep.name LIKE ''%refresh%'' OR ep.name LIKE ''%maxage%'';

        SELECT @TablesWithTimestamp = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        JOIN sys.columns c ON t.object_id = c.object_id
        WHERE c.name LIKE ''%load_date%'' OR c.name LIKE ''%updated_at%'' OR c.name LIKE ''%refresh_time%'' OR c.name LIKE ''%last_load%'';

        IF @TotalTables = 0 SET @DbScore = 0;
        ELSE BEGIN
            DECLARE @SLACoverage FLOAT = CAST(@TablesWithSLA AS FLOAT) / @TotalTables;
            DECLARE @TimestampCoverage FLOAT = CAST(@TablesWithTimestamp AS FLOAT) / @TotalTables;

            IF @SLACoverage >= 0.8 AND @TimestampCoverage >= 0.8 SET @DbScore = 3;
            ELSE IF @SLACoverage >= 0.5 OR @TimestampCoverage >= 0.5 SET @DbScore = 2;
            ELSE IF @SLACoverage > 0 OR @TimestampCoverage > 0 SET @DbScore = 1;
            ELSE SET @DbScore = 0;
        END

        INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);
        ';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
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