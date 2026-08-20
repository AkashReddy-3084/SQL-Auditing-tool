-- Checklist: Metadata accessible to consumers (discoverable)
-- Scope: DATABASE
-- Scoring: 3 = 100% coverage; 2 = >80% coverage; 1 = >20% coverage; 0 = no descriptions found

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
             WHEN COUNT(*) = 0 THEN 0 
             WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) = 1 THEN 3
             WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.8 THEN 2
             WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.2 THEN 1
             ELSE 0 
           END,
           'Coverage: ' + CAST(CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,2)) + '%'
    FROM (
        SELECT o.object_id, 0 as minor_id FROM sys.objects o WHERE o.type IN ('U', 'V')
        UNION ALL
        SELECT o.object_id, c.column_id FROM sys.objects o JOIN sys.columns c ON o.object_id = c.object_id WHERE o.type IN ('U', 'V')
    ) as targets
    LEFT JOIN sys.extended_properties ep ON ep.major_id = targets.object_id AND ep.minor_id = targets.minor_id AND ep.name = 'MS_Description';
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
                  WHEN COUNT(*) = 0 THEN 0 
                  WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) = 1 THEN 3
                  WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.8 THEN 2
                  WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.2 THEN 1
                  ELSE 0 
                END,
                ''Coverage: '' + CAST(CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,2)) + ''%''
                FROM (
                    SELECT o.object_id, 0 as minor_id FROM ' + QUOTENAME(@DbName) + N'.sys.objects o WHERE o.type IN (''U'', ''V'')
                    UNION ALL
                    SELECT o.object_id, c.column_id FROM ' + QUOTENAME(@DbName) + N'.sys.objects o JOIN ' + QUOTENAME(@DbName) + N'.sys.columns c ON o.object_id = c.object_id WHERE o.type IN (''U'', ''V'')
                ) as targets
                LEFT JOIN ' + QUOTENAME(@DbName) + N'.sys.extended_properties ep ON ep.major_id = targets.object_id AND ep.minor_id = targets.minor_id AND ep.name = ''MS_Description'';';

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