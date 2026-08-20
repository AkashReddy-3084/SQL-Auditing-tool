-- Checklist: Query Store used to detect regressions and force plans where needed
-- Scope: DATABASE
-- Scoring: 3 = QS ON and >=1 plan forced; 2 = QS ON, 0 forced; 1 = QS OFF; 0 = not readable

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT 
        DB_NAME(),
        CASE 
            WHEN (SELECT actual_state FROM sys.database_query_store_options) = 0 THEN 1
            WHEN EXISTS (SELECT 1 FROM sys.query_store_plan WHERE is_forced_plan = 1) THEN 3
            ELSE 2 
        END,
        CASE 
            WHEN (SELECT actual_state FROM sys.database_query_store_options) = 0 THEN 'Query Store is OFF'
            WHEN EXISTS (SELECT 1 FROM sys.query_store_plan WHERE is_forced_plan = 1) THEN 'Query Store ON: Plans forced'
            ELSE 'Query Store ON: No plans forced'
        END;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            DECLARE @InnerScore INT, @InnerFinding NVARCHAR(MAX);
            SET @Sql = N'SELECT @s = CASE WHEN (SELECT actual_state FROM ' + QUOTENAME(@DbName) + N'.sys.database_query_store_options) = 0 THEN 1 WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.query_store_plan WHERE is_forced_plan = 1) THEN 3 ELSE 2 END, @f = CASE WHEN (SELECT actual_state FROM ' + QUOTENAME(@DbName) + N'.sys.database_query_store_options) = 0 THEN ''Query Store is OFF'' WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.query_store_plan WHERE is_forced_plan = 1) THEN ''Query Store ON: Plans forced'' ELSE ''Query Store ON: No plans forced'' END';
            EXEC sp_executesql @Sql, N'@s INT OUTPUT, @f NVARCHAR(MAX) OUTPUT', @s = @InnerScore OUTPUT, @f = @InnerFinding OUTPUT;
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @InnerScore, @InnerFinding);
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Evaluation failed: ' + ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;