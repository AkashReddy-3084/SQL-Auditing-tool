-- Checklist: Extended properties / documentation on key objects
-- Scope: DATABASE
-- Scoring: 3 = 100% documented; 2 = >75% documented; 1 = >25% documented; 0 = <=25% or no objects found.

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
          WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) = 1.0 THEN 3
          WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) > 0.75 THEN 2
          WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) > 0.25 THEN 1
          ELSE 0 
        END,
        'Objects documented: ' + CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' of ' + CAST(COUNT(*) AS VARCHAR(10))
    FROM (
        SELECT t.object_id, NULL as column_id FROM sys.tables t
        UNION ALL
        SELECT t.object_id, c.column_id FROM sys.tables t JOIN sys.columns c ON t.object_id = c.object_id
        UNION ALL
        SELECT v.object_id, NULL as column_id FROM sys.views v
    ) AS objs
    LEFT JOIN sys.extended_properties ep ON ep.major_id = objs.object_id 
        AND (ep.minor_id = objs.column_id OR (objs.column_id IS NULL AND ep.minor_id = 0))
        AND ep.name = 'MS_Description';
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
                  WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) = 1.0 THEN 3
                  WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) > 0.75 THEN 2
                  WHEN CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) > 0.25 THEN 1
                  ELSE 0 
                END,
                ''Objects documented: '' + CAST(SUM(CASE WHEN ep.value IS NOT NULL THEN 1 ELSE 0 END) AS VARCHAR(10)) + '' of '' + CAST(COUNT(*) AS VARCHAR(10))
                FROM (
                    SELECT t.object_id, NULL as column_id FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
                    UNION ALL
                    SELECT t.object_id, c.column_id FROM ' + QUOTENAME(@DbName) + N'.sys.tables t JOIN ' + QUOTENAME(@DbName) + N'.sys.columns c ON t.object_id = c.object_id
                    UNION ALL
                    SELECT v.object_id, NULL as column_id FROM ' + QUOTENAME(@DbName) + N'.sys.views v
                ) AS objs
                LEFT JOIN ' + QUOTENAME(@DbName) + N'.sys.extended_properties ep ON ep.major_id = objs.object_id 
                    AND (ep.minor_id = objs.column_id OR (objs.column_id IS NULL AND ep.minor_id = 0))
                    AND ep.name = ''MS_Description'';';

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