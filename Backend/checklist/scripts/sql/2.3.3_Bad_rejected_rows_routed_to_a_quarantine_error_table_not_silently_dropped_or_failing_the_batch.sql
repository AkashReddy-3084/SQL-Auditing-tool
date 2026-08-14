-- Checklist: Bad/rejected rows routed to a quarantine/error table (not silently dropped or failing the batch)
-- Scope: DATABASE
-- Scoring: 0=No error tables found; 1=Error tables exist but not referenced by ETL procs; 2=Error tables exist and referenced by ETL procs; 3=Fully automated verification (not applicable for proxy evidence, capped at 2)
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
        DECLARE @ErrorTableCount INT = 0;
        DECLARE @ProcRefCount INT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @ErrorTableCount = COUNT(*)
        FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.is_ms_shipped = 0
        AND (t.name LIKE ''%error%'' OR t.name LIKE ''%quarantine%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%bad%'');

        IF @ErrorTableCount > 0
        BEGIN
            SELECT @ProcRefCount = COUNT(DISTINCT p.object_id)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE m.definition IS NOT NULL
            AND EXISTS (
                SELECT 1 FROM sys.tables t2 JOIN sys.schemas s2 ON t2.schema_id = s2.schema_id
                WHERE t2.is_ms_shipped = 0
                AND (t2.name LIKE ''%error%'' OR t2.name LIKE ''%quarantine%'' OR t2.name LIKE ''%reject%'' OR t2.name LIKE ''%bad%'')
                AND (m.definition LIKE ''%'' + s2.name + ''.'' + t2.name + ''%'' OR m.definition LIKE ''%'' + QUOTENAME(s2.name) + ''.'' + QUOTENAME(t2.name) + ''%'')
            );

            IF @ProcRefCount > 0 SET @DbScore = 2;
            ELSE SET @DbScore = 1;
        END
        ELSE
        BEGIN
            SET @DbScore = 0;
        END

        INSERT INTO #DbResults VALUES (DB_NAME(), @DbScore);
        ';
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