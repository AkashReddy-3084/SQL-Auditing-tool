-- Checklist: Failed loads are restartable from point of failure (not full re-run)
-- Scope: DATABASE
-- Scoring: 0=No ETL procs, 1=ETL procs but no checkpoint/control evidence, 2=Checkpoint keywords or control tables found, 3=Strong proxy evidence (capped at 2 for indirect scanning)
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
        DECLARE @ETLCount INT = 0;
        DECLARE @CheckpointCount INT = 0;
        DECLARE @ControlTableCount INT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @ETLCount = COUNT(*) FROM sys.procedures
        WHERE name LIKE ''usp_Load%'' OR name LIKE ''proc_ETL%'' OR name LIKE ''sp_Ingest%'' OR name LIKE ''%Load%'';

        SELECT @CheckpointCount = COUNT(*) FROM sys.procedures p
        CROSS APPLY (SELECT 1 FROM sys.sql_modules m WHERE m.object_id = p.object_id
                     AND (m.definition LIKE ''%@BatchID%'' OR m.definition LIKE ''%@RunID%'' OR m.definition LIKE ''%@LastRun%''
                          OR m.definition LIKE ''%LoadStatus%'' OR m.definition LIKE ''%Checkpoint%''
                          OR m.definition LIKE ''%Incremental%'' OR m.definition LIKE ''%ModifiedDate%''
                          OR m.definition LIKE ''%MERGE%'' OR m.definition LIKE ''%TRY%'' OR m.definition LIKE ''%CATCH%'')) AS ca;

        SELECT @ControlTableCount = COUNT(*) FROM sys.tables
        WHERE name LIKE ''%Control%'' OR name LIKE ''%Metadata%'' OR name LIKE ''%LoadLog%'' OR name LIKE ''%Batch%'';

        IF @ETLCount = 0 SET @DbScore = 0;
        ELSE IF @CheckpointCount = 0 AND @ControlTableCount = 0 SET @DbScore = 1;
        ELSE IF @CheckpointCount > 0 OR @ControlTableCount > 0 SET @DbScore = 2;
        ELSE IF @CheckpointCount > 0 AND @ControlTableCount > 0 SET @DbScore = 2;

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

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;