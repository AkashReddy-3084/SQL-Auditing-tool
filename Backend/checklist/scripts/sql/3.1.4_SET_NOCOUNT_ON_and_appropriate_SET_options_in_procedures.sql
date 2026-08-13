-- Checklist: SET NOCOUNT ON and appropriate SET options in procedures
-- Scope: DATABASE
-- Scoring: 0=0% procs have SET NOCOUNT ON, 1=1-49%, 2=50-99%, 3=100%
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
        DECLARE @TotalProcs INT = 0;
        DECLARE @ProcsWithNocount INT = 0;
        SELECT @TotalProcs = COUNT(*) FROM sys.procedures p
        INNER JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0 AND m.definition IS NOT NULL;
        SELECT @ProcsWithNocount = COUNT(*) FROM sys.procedures p
        INNER JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0 AND m.definition IS NOT NULL AND UPPER(m.definition) LIKE ''%SET NOCOUNT ON%'';
        
        DECLARE @DbScore INT = 0;
        IF @TotalProcs = 0 SET @DbScore = 3;
        ELSE BEGIN
            DECLARE @Pct FLOAT = (@ProcsWithNocount * 100.0) / @TotalProcs;
            IF @Pct >= 100 SET @DbScore = 3;
            ELSE IF @Pct >= 50 SET @DbScore = 2;
            ELSE IF @Pct > 0 SET @DbScore = 1;
            ELSE SET @DbScore = 0;
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

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;