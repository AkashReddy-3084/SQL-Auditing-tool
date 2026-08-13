-- Checklist: XACT_ABORT / transaction state handling correct on error
-- Scope: DATABASE
-- Scoring: 0 = 0% of procedures contain error handling patterns; 1 = 1-49%; 2 = 50-89%; 3 = 90-100%
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
        DECLARE @Total INT = (SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0);
        DECLARE @Matched INT = (SELECT COUNT(*) FROM sys.procedures p
                                JOIN sys.sql_modules m ON p.object_id = m.object_id
                                WHERE p.is_ms_shipped = 0
                                  AND (m.definition LIKE ''%XACT_ABORT%''
                                       OR m.definition LIKE ''%XACT_STATE%''
                                       OR (m.definition LIKE ''%BEGIN TRY%'' AND m.definition LIKE ''%BEGIN CATCH%'')));
        DECLARE @DbScore INT = 0;
        IF @Total = 0 SET @DbScore = 3;
        ELSE BEGIN
            DECLARE @Pct FLOAT = (@Matched * 100.0) / @Total;
            SET @DbScore = CASE
                WHEN @Pct >= 90 THEN 3
                WHEN @Pct >= 50 THEN 2
                WHEN @Pct >= 1 THEN 1
                ELSE 0
            END;
        END;
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