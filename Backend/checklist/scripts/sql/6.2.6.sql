-- Checklist: Sensitive data classified (SQL Data Discovery & Classification / labels)
-- Scope: DATABASE
-- Scoring: 3 = labels exist in all queried databases; 2 = labels exist in some databases; 1 = labels exist but very few; 0 = no labels found

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
           CASE WHEN COUNT(*) > 0 THEN 3 ELSE 0 END,
           CASE WHEN COUNT(*) > 0 THEN 'Labels found: ' + STRING_AGG(CAST(label.name AS NVARCHAR(MAX)), ', ') 
                ELSE 'No sensitivity labels found' END
    FROM sys.sensitivity_classifications AS label
    JOIN sys.columns AS col ON label.major_id = col.object_id AND label.minor_id = col.column_id;
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
                CASE WHEN COUNT(*) > 0 THEN 3 ELSE 0 END,
                CASE WHEN COUNT(*) > 0 THEN ''Labels found: '' + STRING_AGG(CAST(label.name AS NVARCHAR(MAX)), '', '') 
                     ELSE ''No sensitivity labels found'' END
                FROM ' + QUOTENAME(@DbName) + N'.sys.sensitivity_classifications AS label
                JOIN ' + QUOTENAME(@DbName) + N'.sys.columns AS col ON label.major_id = col.object_id AND label.minor_id = col.column_id;';

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

-- Aggregate results
DECLARE @TotalDbs INT = (SELECT COUNT(*) FROM #DbResults);
DECLARE @PassDbs INT = (SELECT COUNT(*) FROM #DbResults WHERE DbScore = 3);

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');

IF @TotalDbs = 0
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SET @Score = CASE 
        WHEN @PassDbs = @TotalDbs THEN 3 
        WHEN @PassDbs > 0 AND @PassDbs >= (@TotalDbs / 2.0) THEN 2 
        WHEN @PassDbs > 0 THEN 1
        ELSE 0 END;
    
    SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No labels found');
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;