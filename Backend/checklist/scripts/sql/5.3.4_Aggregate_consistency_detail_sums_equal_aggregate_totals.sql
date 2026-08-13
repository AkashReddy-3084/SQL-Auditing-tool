-- Checklist: Aggregate consistency: detail sums equal aggregate totals
-- Scope: DATABASE
-- Scoring: 0=No aggregate tables found, 1=Aggregates exist but no structural enforcement or reconciliation jobs, 2=Aggregates exist with indexed views OR reconciliation jobs, 3=Not applicable (proxy evidence capped at 2 per guidelines)
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
        DECLARE @AggCount INT = 0;
        DECLARE @IndexedViewCount INT = 0;
        DECLARE @JobCount INT = 0;

        SELECT @AggCount = COUNT(*) FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE s.name + ''.'' + t.name LIKE ''%agg%'' OR s.name + ''.'' + t.name LIKE ''%sum%'' OR s.name + ''.'' + t.name LIKE ''%total%'' OR s.name + ''.'' + t.name LIKE ''%mart%'';

        SELECT @IndexedViewCount = COUNT(*) FROM sys.views v
        JOIN sys.schemas s ON v.schema_id = s.schema_id
        WHERE OBJECTPROPERTY(v.object_id, ''IsSchemaBound'') = 1
          AND OBJECTPROPERTY(v.object_id, ''IsIndexedView'') = 1
          AND (s.name + ''.'' + v.name LIKE ''%agg%'' OR s.name + ''.'' + v.name LIKE ''%sum%'' OR s.name + ''.'' + v.name LIKE ''%total%'');

        -- Scope job check to the current database using sysjobsteps.database_name
        SELECT @JobCount = COUNT(*) FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
        WHERE (j.name LIKE ''%reconcile%'' OR j.name LIKE ''%validate%'' OR j.name LIKE ''%aggregate%'')
          AND js.database_name = DB_NAME();

        DECLARE @DbScore INT = 0;
        IF @AggCount = 0 SET @DbScore = 0;
        ELSE IF @IndexedViewCount = 0 AND @JobCount = 0 SET @DbScore = 1;
        ELSE SET @DbScore = 2;

        INSERT INTO #DbResults (DbName, DbScore) VALUES (@DbNameParam, @DbScore);
        ';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore) VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;