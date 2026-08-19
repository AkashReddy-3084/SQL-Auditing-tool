-- Checklist: Parameter sniffing issues identified and mitigated (OPTIMIZE FOR, recompile, etc.)
-- Scope: DATABASE
-- Scoring: 3 = all procedures use mitigations; 2 = >50% use mitigations; 1 = some use mitigations; 0 = none use mitigations

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
             WHEN COUNT(*) = 0 THEN 3 
             WHEN SUM(CASE WHEN m.definition LIKE '%OPTIMIZE FOR%' OR m.definition LIKE '%RECOMPILE%' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) = 1 THEN 3
             WHEN SUM(CASE WHEN m.definition LIKE '%OPTIMIZE FOR%' OR m.definition LIKE '%RECOMPILE%' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) >= 0.5 THEN 2
             WHEN SUM(CASE WHEN m.definition LIKE '%OPTIMIZE FOR%' OR m.definition LIKE '%RECOMPILE%' THEN 1 ELSE 0 END) > 0 THEN 1
             ELSE 0 
           END,
           CASE 
             WHEN COUNT(*) = 0 THEN 'No stored procedures found'
             ELSE 'Mitigated: ' + CAST(SUM(CASE WHEN m.definition LIKE '%OPTIMIZE FOR%' OR m.definition LIKE '%RECOMPILE%' THEN 1 ELSE 0 END) AS VARCHAR) + ' / Total: ' + CAST(COUNT(*) AS VARCHAR)
           END
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id;
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
                  WHEN COUNT(*) = 0 THEN 3 
                  WHEN SUM(CASE WHEN m.definition LIKE ''%OPTIMIZE FOR%'' OR m.definition LIKE ''%RECOMPILE%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) = 1 THEN 3
                  WHEN SUM(CASE WHEN m.definition LIKE ''%OPTIMIZE FOR%'' OR m.definition LIKE ''%RECOMPILE%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) >= 0.5 THEN 2
                  WHEN SUM(CASE WHEN m.definition LIKE ''%OPTIMIZE FOR%'' OR m.definition LIKE ''%RECOMPILE%'' THEN 1 ELSE 0 END) > 0 THEN 1
                  ELSE 0 
                END,
                CASE 
                  WHEN COUNT(*) = 0 THEN ''No stored procedures found''
                  ELSE ''Mitigated: '' + CAST(SUM(CASE WHEN m.definition LIKE ''%OPTIMIZE FOR%'' OR m.definition LIKE ''%RECOMPILE%'' THEN 1 ELSE 0 END) AS VARCHAR) + '' / Total: '' + CAST(COUNT(*) AS VARCHAR)
                END
                FROM ' + QUOTENAME(@DbName) + N'.sys.procedures p
                JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules m ON p.object_id = m.object_id;';

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

-- Use dynamic SQL for STRING_AGG to ensure compatibility with older versions or handle via XML path
IF (SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS INT)) >= 14
BEGIN
    SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
    SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
END
ELSE
BEGIN
    SET @DatabaseQueried = ISNULL(CAST((SELECT STUFF((SELECT ', ' + DbName FROM #DbResults FOR XML PATH('')), 1, 2, '')) AS NVARCHAR(MAX)), 'None');
    SET @Finding = ISNULL(CAST((SELECT STUFF((SELECT '; ' + DbName + ': ' + Finding FROM #DbResults FOR XML PATH('')), 1, 2, '')) AS NVARCHAR(MAX)), 'No database found to be queried');
END

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;