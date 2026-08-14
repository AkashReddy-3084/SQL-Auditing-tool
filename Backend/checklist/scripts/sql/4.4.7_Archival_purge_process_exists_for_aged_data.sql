-- Checklist: Archival/purge process exists for aged data
-- Scope: DATABASE
-- Scoring: 0=No evidence found; 1=Partition functions exist (proxy for aged data management) but no explicit purge logic; 2=Stored procedures found containing archival/purge keywords (partial evidence, requires human review); 3=Not achievable automatically as process validation requires code inspection
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
        DECLARE @HasPartition INT = 0;
        DECLARE @HasPurgeProc INT = 0;

        -- Check for partition functions (proxy for aged data management strategy)
        IF EXISTS (SELECT 1 FROM sys.partition_functions) SET @HasPartition = 1;

        -- Check for procedures/modules with archival/purge keywords
        IF EXISTS (
            SELECT 1 FROM sys.procedures p
            INNER JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE m.definition LIKE ''%archive%'' OR m.definition LIKE ''%purge%'' OR m.definition LIKE ''%delete%'' OR m.definition LIKE ''%history%'' OR m.definition LIKE ''%switch%'' OR m.definition LIKE ''%retention%'' OR m.definition LIKE ''%cleanup%''
               OR p.name LIKE ''%archive%'' OR p.name LIKE ''%purge%'' OR p.name LIKE ''%cleanup%''
        ) SET @HasPurgeProc = 1;

        IF @HasPurgeProc = 1 SET @DbScore = 2;
        ELSE IF @HasPartition = 1 SET @DbScore = 1;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        ';
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.