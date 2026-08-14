-- Checklist: Baselines captured for comparison over time
-- Scope: DATABASE
-- Scoring: 0=No evidence; 1=Proxy evidence (baseline tables found); 2=Query Store enabled but Read-Only; 3=Query Store enabled in Read-Write mode (direct config verification)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @DbScore = 0;
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @QSState INT = 0;
        DECLARE @BaselineCount INT = 0;

        SELECT @QSState = ISNULL(actual_state, 0) FROM sys.database_query_store_options;

        SELECT @BaselineCount = COUNT(*) FROM sys.tables WHERE name LIKE ''%baseline%'' OR name LIKE ''%snapshot%'' OR name LIKE ''%perf%'';

        IF @QSState = 2 SET @DbScore = 3;
        ELSE IF @QSState = 1 SET @DbScore = 2;
        ELSE IF @BaselineCount > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        SELECT @DbScore;';
        
        INSERT INTO #DbResults (DbName, DbScore)
        EXEC sp_executesql @Sql;
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