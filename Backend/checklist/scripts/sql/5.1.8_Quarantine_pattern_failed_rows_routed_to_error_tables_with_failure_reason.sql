-- Checklist: Quarantine pattern: failed rows routed to error tables with failure reason
-- Scope: DATABASE
-- Scoring: 0=No error tables found; 1=Error tables found but lack failure reason columns; 2=Error tables with failure reason columns found; 3=Error tables with failure reason columns found and actively populated (rowcount > 0)
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
        DECLARE @HasTable INT = 0;
        DECLARE @HasReason INT = 0;
        DECLARE @HasRows INT = 0;

        SELECT @HasTable = COUNT(*) FROM sys.tables t
        WHERE t.name LIKE ''%error%'' OR t.name LIKE ''%quarantine%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%fail%'' OR t.name LIKE ''%bad%'' OR t.name LIKE ''%exception%'';

        IF @HasTable > 0
        BEGIN
            SELECT @HasReason = COUNT(*) FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            WHERE t.name LIKE ''%error%'' OR t.name LIKE ''%quarantine%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%fail%'' OR t.name LIKE ''%bad%'' OR t.name LIKE ''%exception%''
            AND (c.name LIKE ''%reason%'' OR c.name LIKE ''%message%'' OR c.name LIKE ''%status%'' OR c.name LIKE ''%desc%'' OR c.name LIKE ''%error%'');

            IF @HasReason > 0
            BEGIN
                SELECT @HasRows = ISNULL(SUM(p.rows), 0) FROM sys.tables t
                JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0,1)
                WHERE t.name LIKE ''%error%'' OR t.name LIKE ''%quarantine%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%fail%'' OR t.name LIKE ''%bad%'' OR t.name LIKE ''%exception%''
                AND EXISTS (
                    SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND (c.name LIKE ''%reason%'' OR c.name LIKE ''%message%'' OR c.name LIKE ''%status%'' OR c.name LIKE ''%desc%'' OR c.name LIKE ''%error%'')
                );
            END
        END

        DECLARE @DbScore INT = 0;
        IF @HasTable = 0 SET @DbScore = 0;
        ELSE IF @HasReason = 0 SET @DbScore = 1;
        ELSE IF @HasRows > 0 SET @DbScore = 3;
        ELSE SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);';
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