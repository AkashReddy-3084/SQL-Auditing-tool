-- Checklist: Insert/Update/Delete operations handled correctly (MERGE or equivalent)
-- Scope: DATABASE
-- Scoring: 3 = all modification procs use MERGE; 2 = >80% use MERGE; 1 = some use MERGE; 0 = none use MERGE or no procs found

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
            WHEN SUM(CASE WHEN definition LIKE '%MERGE%' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) = 1 THEN 3
            WHEN SUM(CASE WHEN definition LIKE '%MERGE%' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) >= 0.8 THEN 2
            WHEN SUM(CASE WHEN definition LIKE '%MERGE%' THEN 1 ELSE 0 END) > 0 THEN 1
            ELSE 0 
        END,
        'Procs with modifications: ' + CAST(COUNT(*) AS VARCHAR(10)) + ', MERGE-based: ' + CAST(SUM(CASE WHEN definition LIKE '%MERGE%' THEN 1 ELSE 0 END) AS VARCHAR(10))
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE (definition LIKE '%INSERT%' OR definition LIKE '%UPDATE%' OR definition LIKE '%DELETE%' OR definition LIKE '%MERGE%');
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
            SET @Sql = N'SELECT 
                @p_Db,
                CASE 
                    WHEN COUNT(*) = 0 THEN 0 
                    WHEN SUM(CASE WHEN definition LIKE ''%MERGE%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) = 1 THEN 3
                    WHEN SUM(CASE WHEN definition LIKE ''%MERGE%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) >= 0.8 THEN 2
                    WHEN SUM(CASE WHEN definition LIKE ''%MERGE%'' THEN 1 ELSE 0 END) > 0 THEN 1
                    ELSE 0 
                END,
                ''Procs with modifications: '' + CAST(COUNT(*) AS VARCHAR(10)) + '', MERGE-based: '' + CAST(SUM(CASE WHEN definition LIKE ''%MERGE%'' THEN 1 ELSE 0 END) AS VARCHAR(10))
                FROM ' + QUOTENAME(@DbName) + N'.sys.procedures p
                JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules m ON p.object_id = m.object_id
                WHERE (definition LIKE ''%INSERT%'' OR definition LIKE ''%UPDATE%'' OR definition LIKE ''%DELETE%'' OR definition LIKE ''%MERGE%'');';

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

IF @DatabaseQueried = 'None'
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;