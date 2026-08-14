-- Checklist: Multi-step operations maintain integrity on partial failure
-- Scope: DATABASE
-- Scoring: 0=No transaction control found, 1=1-49% procs use transactions, 2=50-100% procs use transactions. Capped at 2 as keyword scanning is proxy evidence requiring human review of transaction boundaries.
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
        DECLARE @TotalProcs INT;
        DECLARE @TxProcs INT;
        
        SELECT @TotalProcs = COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0;
        
        SELECT @TxProcs = COUNT(*) FROM sys.procedures p
        INNER JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
        AND (m.definition LIKE ''%BEGIN TRAN%'' OR m.definition LIKE ''%BEGIN TRANSACTION%'');
        
        DECLARE @Ratio DECIMAL(5,2) = CASE WHEN @TotalProcs > 0 THEN CAST(@TxProcs AS DECIMAL) / @TotalProcs ELSE 0 END;
        DECLARE @DbScore INT = 0;
        IF @Ratio >= 0.50 SET @DbScore = 2;
        ELSE IF @Ratio > 0.00 SET @DbScore = 1;
        
        INSERT INTO #DbResults VALUES (@pDbName, @DbScore);
        ';
        EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(256)', @pDbName = @DbName;
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