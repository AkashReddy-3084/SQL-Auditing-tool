-- Checklist: DQ rules codified (config-driven or reusable procedures), not ad-hoc manual checks
-- Scope: DATABASE
-- Scoring: 3 = multiple DQ procedures and config tables found; 2 = some DQ objects found; 1 = minimal evidence (1 object); 0 = no DQ objects found.

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
    SELECT DB_NAME(),
           CASE 
               WHEN (dq_count + cfg_count) >= 3 THEN 3 
               WHEN (dq_count + cfg_count) >= 2 THEN 2 
               WHEN (dq_count + cfg_count) = 1 THEN 1 
               ELSE 0 
           END,
           'DQ Objects: ' + CAST(dq_count AS VARCHAR(10)) + ', Config Tables: ' + CAST(cfg_count AS VARCHAR(10))
    FROM (
        SELECT 
            (SELECT COUNT(*) FROM sys.procedures p JOIN sys.sql_modules m ON p.object_id = m.object_id 
             WHERE p.name LIKE '%dq%' OR p.name LIKE '%validate%' OR p.name LIKE '%check%') as dq_count,
            (SELECT COUNT(*) FROM sys.tables t WHERE t.name LIKE '%dq_config%' OR t.name LIKE '%dq_rules%') as cfg_count
    ) AS counts;
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
            SET @Sql = N'SELECT @p_Db,
                CASE 
                    WHEN (dq_count + cfg_count) >= 3 THEN 3 
                    WHEN (dq_count + cfg_count) >= 2 THEN 2 
                    WHEN (dq_count + cfg_count) = 1 THEN 1 
                    ELSE 0 
                END,
                ''DQ Objects: '' + CAST(dq_count AS VARCHAR(10)) + '', Config Tables: '' + CAST(cfg_count AS VARCHAR(10))
                FROM (
                    SELECT 
                        (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.procedures p JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules m ON p.object_id = m.object_id 
                         WHERE p.name LIKE ''%dq%'' OR p.name LIKE ''%validate%'' OR p.name LIKE ''%check%'') as dq_count,
                        (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables t WHERE t.name LIKE ''%dq_config%'' OR t.name LIKE ''%dq_rules%'') as cfg_count
                ) AS counts;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
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