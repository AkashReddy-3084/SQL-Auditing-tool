-- Checklist: Retry logic exists for transient failures
-- Scope: DATABASE
-- Scoring: 3 = retry patterns found in all modules; 2 = >50% of modules; 1 = some modules; 0 = none found
-- NOTE: Automated evidence only; full compliance requires human review.

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
            WHEN COUNT(*) = 0 THEN 0 
            WHEN SUM(CASE WHEN m.definition LIKE '%WHILE%' AND m.definition LIKE '%TRY%' AND m.definition LIKE '%CATCH%' AND m.definition LIKE '%WAITFOR%' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) >= 1.0 THEN 3
            WHEN SUM(CASE WHEN m.definition LIKE '%WHILE%' AND m.definition LIKE '%TRY%' AND m.definition LIKE '%CATCH%' AND m.definition LIKE '%WAITFOR%' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) >= 0.5 THEN 2
            WHEN SUM(CASE WHEN m.definition LIKE '%WHILE%' AND m.definition LIKE '%TRY%' AND m.definition LIKE '%CATCH%' AND m.definition LIKE '%WAITFOR%' THEN 1 ELSE 0 END) > 0 THEN 1
            ELSE 0 
        END,
        CASE 
            WHEN COUNT(*) = 0 THEN 'No programmable objects found'
            WHEN SUM(CASE WHEN m.definition LIKE '%WHILE%' AND m.definition LIKE '%TRY%' AND m.definition LIKE '%CATCH%' AND m.definition LIKE '%WAITFOR%' THEN 1 ELSE 0 END) = 0 THEN 'No retry patterns (WHILE+TRY+CATCH+WAITFOR) found'
            ELSE 'Retry patterns found in ' + CAST(SUM(CASE WHEN m.definition LIKE '%WHILE%' AND m.definition LIKE '%TRY%' AND m.definition LIKE '%CATCH%' AND m.definition LIKE '%WAITFOR%' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' of ' + CAST(COUNT(*) AS VARCHAR(10)) + ' objects'
        END
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.type IN ('P', 'FN', 'IF', 'TF');
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
            SET @Sql = N'SELECT ' + QUOTENAME(@DbName, '''') + N',
                CASE 
                    WHEN COUNT(*) = 0 THEN 0 
                    WHEN SUM(CASE WHEN m.definition LIKE ''%WHILE%'' AND m.definition LIKE ''%TRY%'' AND m.definition LIKE ''%CATCH%'' AND m.definition LIKE ''%WAITFOR%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) >= 1.0 THEN 3
                    WHEN SUM(CASE WHEN m.definition LIKE ''%WHILE%'' AND m.definition LIKE ''%TRY%'' AND m.definition LIKE ''%CATCH%'' AND m.definition LIKE ''%WAITFOR%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) >= 0.5 THEN 2
                    WHEN SUM(CASE WHEN m.definition LIKE ''%WHILE%'' AND m.definition LIKE ''%TRY%'' AND m.definition LIKE ''%CATCH%'' AND m.definition LIKE ''%WAITFOR%'' THEN 1 ELSE 0 END) > 0 THEN 1
                    ELSE 0 
                END,
                CASE 
                    WHEN COUNT(*) = 0 THEN ''No programmable objects found''
                    WHEN SUM(CASE WHEN m.definition LIKE ''%WHILE%'' AND m.definition LIKE ''%TRY%'' AND m.definition LIKE ''%CATCH%'' AND m.definition LIKE ''%WAITFOR%'' THEN 1 ELSE 0 END) = 0 THEN ''No retry patterns (WHILE+TRY+CATCH+WAITFOR) found''
                    ELSE ''Retry patterns found in '' + CAST(SUM(CASE WHEN m.definition LIKE ''%WHILE%'' AND m.definition LIKE ''%TRY%'' AND m.definition LIKE ''%CATCH%'' AND m.definition LIKE ''%WAITFOR%'' THEN 1 ELSE 0 END) AS VARCHAR(10)) + '' of '' + CAST(COUNT(*) AS VARCHAR(10)) + '' objects''
                END
                FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m
                JOIN ' + QUOTENAME(@DbName) + N'.sys.objects o ON m.object_id = o.object_id
                WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'');';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Evaluation failed: ' + ERROR_MESSAGE());
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