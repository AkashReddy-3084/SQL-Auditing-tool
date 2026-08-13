-- Checklist: Multi-step operations maintain consistency on partial failure
-- Scope: SERVER
-- Scoring: 0 = <30% coverage. 1 = 30-79% coverage. 2 = >=80% coverage. NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalProcs INT = 0;
DECLARE @ProcsWithTrans INT = 0;
DECLARE @ProcsWithErrorHandling INT = 0;
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#DbStats') IS NOT NULL DROP TABLE #DbStats;
CREATE TABLE #DbStats (DbName NVARCHAR(256), TotalProcs INT, ProcsWithTrans INT, ProcsWithErrorHandling INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT ''' + @DbName + N''',
               COUNT(*) AS TotalProcs,
               SUM(CASE WHEN definition LIKE ''%BEGIN TRAN%'' OR definition LIKE ''%XACT_ABORT%'' OR definition LIKE ''%COMMIT TRAN%'' THEN 1 ELSE 0 END) AS ProcsWithTrans,
               SUM(CASE WHEN definition LIKE ''%TRY%'' AND definition LIKE ''%CATCH%'' THEN 1 ELSE 0 END) AS ProcsWithErrorHandling
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0;';
        INSERT INTO #DbStats EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbStats VALUES (@DbName, 0, 0, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @TotalProcs = ISNULL(SUM(TotalProcs), 0),
       @ProcsWithTrans = ISNULL(SUM(ProcsWithTrans), 0),
       @ProcsWithErrorHandling = ISNULL(SUM(ProcsWithErrorHandling), 0)
FROM #DbStats;

IF @TotalProcs = 0
    SET @Score = 0;
ELSE BEGIN
    DECLARE @TransPct FLOAT = CAST(@ProcsWithTrans AS FLOAT) / @TotalProcs;
    DECLARE @ErrPct FLOAT = CAST(@ProcsWithErrorHandling AS FLOAT) / @TotalProcs;
    DECLARE @MinPct FLOAT = CASE WHEN @TransPct < @ErrPct THEN @TransPct ELSE @ErrPct END;

    IF @MinPct >= 0.8 SET @Score = 2;
    ELSE IF @MinPct >= 0.3 SET @Score = 1;
    ELSE SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbStats;
SELECT @Result AS Result, @Score AS Score;