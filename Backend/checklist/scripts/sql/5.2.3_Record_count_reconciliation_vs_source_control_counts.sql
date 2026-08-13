-- Checklist: Record count reconciliation vs. source control counts
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Basic count checks only, 2=Reconciliation logic OR control tables found. Capped at 2 due to proxy evidence.
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
        DECLARE @BasicCount INT = 0;
        DECLARE @ReconLogic INT = 0;
        DECLARE @ControlTables INT = 0;

        -- Check for basic row count usage in ETL modules
        SELECT @BasicCount = COUNT(*) FROM sys.procedures p
        CROSS APPLY sys.sql_modules m(p.object_id)
        WHERE m.definition LIKE ''%COUNT%'' OR m.definition LIKE ''%@@ROWCOUNT%'';

        -- Check for explicit reconciliation/comparison logic
        SELECT @ReconLogic = COUNT(*) FROM sys.procedures p
        CROSS APPLY sys.sql_modules m(p.object_id)
        WHERE m.definition LIKE ''%RECONCILE%'' OR m.definition LIKE ''%MISMATCH%''
           OR m.definition LIKE ''%SOURCE_COUNT%'' OR m.definition LIKE ''%TARGET_COUNT%''
           OR m.definition LIKE ''%LOAD_COUNT%'' OR m.definition LIKE ''%COMPARE%'';

        -- Check for control/audit tables tracking load metrics
        SELECT @ControlTables = COUNT(*) FROM sys.tables t
        WHERE t.name LIKE ''%ETL_LOG%'' OR t.name LIKE ''%LOAD_CONTROL%''
           OR t.name LIKE ''%RECONCILE%'' OR t.name LIKE ''%AUDIT%''
           OR t.name LIKE ''%CONTROL%'';

        INSERT INTO #DbResults (DbName, DbScore)
        VALUES (' + QUOTENAME(@DbName, '''') + N',
                CASE
                    WHEN @BasicCount = 0 AND @ReconLogic = 0 AND @ControlTables = 0 THEN 0
                    WHEN @BasicCount > 0 AND @ReconLogic = 0 AND @ControlTables = 0 THEN 1
                    WHEN (@ReconLogic > 0 OR @ControlTables > 0) THEN 2
                    ELSE 0
                END);
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

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;