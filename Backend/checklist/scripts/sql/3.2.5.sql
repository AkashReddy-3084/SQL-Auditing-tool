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
            WHEN COUNT(*) = 0 THEN 3 
            WHEN (CAST(COUNT(*) AS FLOAT) / NULLIF((SELECT COUNT(*) FROM sys.procedures), 0)) < 0.05 THEN 2 
            WHEN (CAST(COUNT(*) AS FLOAT) / NULLIF((SELECT COUNT(*) FROM sys.procedures), 0)) < 0.25 THEN 1 
            ELSE 0 
        END,
        CASE 
            WHEN COUNT(*) = 0 THEN 'No non-compliant dynamic SQL found'
            ELSE 'Non-compliant: ' + STRING_AGG(QUOTENAME(s.name) + '.' + QUOTENAME(p.name), ', ') 
        END
    FROM sys.procedures p
    JOIN sys.schemas s ON p.schema_id = s.schema_id
    CROSS APPLY (SELECT definition FROM sys.sql_modules WHERE object_id = p.object_id) m
    WHERE (m.definition LIKE '%EXEC(%' OR m.definition LIKE '%EXECUTE(%' OR m.definition LIKE '%sp_executesql%')
      AND (m.definition LIKE '%+%' OR m.definition LIKE '%CONCAT%')
      AND m.definition NOT LIKE '%@%';
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
            SET @Sql = N'
            DECLARE @Total INT = 0;
            SELECT @Total = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.procedures;
            
            SELECT @p_Db,
                CASE 
                    WHEN COUNT(*) = 0 THEN 3 
                    WHEN (CAST(COUNT(*) AS FLOAT) / NULLIF(@Total, 0)) < 0.05 THEN 2 
                    WHEN (CAST(COUNT(*) AS FLOAT) / NULLIF(@Total, 0)) < 0.25 THEN 1 
                    ELSE 0 
                END,
                CASE 
                    WHEN COUNT(*) = 0 THEN ''No non-compliant dynamic SQL found''
                    ELSE ''Non-compliant: '' + STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(p.name), '', '') 
                END
            FROM ' + QUOTENAME(@DbName) + N'.sys.procedures p
            JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON p.schema_id = s.schema_id
            CROSS APPLY (SELECT definition FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules WHERE object_id = p.object_id) m
            WHERE (m.definition LIKE ''%EXEC(%'' OR m.definition LIKE ''%EXECUTE(%'' OR m.definition LIKE ''%sp_executesql%'')
              AND (m.definition LIKE ''%+%'' OR m.definition LIKE ''%CONCAT%'')
              AND m.definition NOT LIKE ''%@%''';

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