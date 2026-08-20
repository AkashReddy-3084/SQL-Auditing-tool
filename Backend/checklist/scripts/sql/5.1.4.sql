-- Checklist: DQ results logged and trended over time
-- Scope: DATABASE
-- Scoring: 3 = DQ tables found with date columns; 2 = DQ tables found without date columns; 1 = Only generic log tables found; 0 = No DQ/Log tables found.

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
            WHEN EXISTS (SELECT 1 FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE (t.name LIKE '%DQ%' OR t.name LIKE '%Quality%') AND (c.name LIKE '%Date%' OR c.name LIKE '%Time%')) THEN 3
            WHEN EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE '%DQ%' OR name LIKE '%Quality%') THEN 2
            WHEN EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE '%Log%' OR name LIKE '%Audit%') THEN 1
            ELSE 0 
        END,
        CASE 
            WHEN EXISTS (SELECT 1 FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE (t.name LIKE '%DQ%' OR t.name LIKE '%Quality%') AND (c.name LIKE '%Date%' OR c.name LIKE '%Time%')) THEN 'DQ tables with date/time columns found'
            WHEN EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE '%DQ%' OR name LIKE '%Quality%') THEN 'DQ tables found but no date/time columns identified'
            WHEN EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE '%Log%' OR name LIKE '%Audit%') THEN 'Only generic log/audit tables found'
            ELSE 'No DQ or logging tables found'
        END;
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
                    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.columns c JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id WHERE (t.name LIKE ''%DQ%'' OR t.name LIKE ''%Quality%'') AND (c.name LIKE ''%Date%'' OR c.name LIKE ''%Time%'')) THEN 3
                    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''%DQ%'' OR name LIKE ''%Quality%'') THEN 2
                    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''%Log%'' OR name LIKE ''%Audit%'') THEN 1
                    ELSE 0 
                END,
                CASE 
                    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.columns c JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id WHERE (t.name LIKE ''%DQ%'' OR t.name LIKE ''%Quality%'') AND (c.name LIKE ''%Date%'' OR c.name LIKE ''%Time%'')) THEN ''DQ tables with date/time columns found''
                    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''%DQ%'' OR name LIKE ''%Quality%'') THEN ''DQ tables found but no date/time columns identified''
                    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''%Log%'' OR name LIKE ''%Audit%'') THEN ''Only generic log/audit tables found''
                    ELSE ''No DQ or logging tables found''
                END';

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