-- Checklist: Date/Time dimension exists with required attributes
-- Scope: DATABASE
-- Scoring: 3 = Date table found with 4+ standard attributes; 2 = Date table found with 1-3 attributes; 1 = Date table found but no standard attributes; 0 = No date table found.

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
            WHEN MAX(AttrCount) >= 4 THEN 3 
            WHEN MAX(AttrCount) BETWEEN 1 AND 3 THEN 2 
            WHEN MAX(TableExists) = 1 THEN 1 
            ELSE 0 
        END,
        CASE 
            WHEN MAX(TableExists) = 0 THEN 'No Date/Time dimension table found'
            ELSE 'Date table found. Matching attributes count: ' + CAST(MAX(AttrCount) AS NVARCHAR(10))
        END
    FROM (
        SELECT 
            1 AS TableExists,
            (SELECT COUNT(DISTINCT c.name) 
             FROM sys.columns c 
             JOIN sys.tables t ON c.object_id = t.object_id 
             WHERE (t.name LIKE '%Date%' OR t.name LIKE '%Time%') 
             AND (c.name LIKE '%Year%' OR c.name LIKE '%Month%' OR c.name LIKE '%Day%' OR c.name LIKE '%Quarter%' OR c.name LIKE '%Week%')) AS AttrCount
        FROM sys.tables 
        WHERE name LIKE '%Date%' OR name LIKE '%Time%'
    ) AS Sub;

    IF NOT EXISTS (SELECT 1 FROM #DbResults WHERE DbScore IS NOT NULL)
    BEGIN
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (DB_NAME(), 0, 'No Date/Time dimension table found');
    END
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
            DECLARE @t_exists INT = 0;
            DECLARE @a_count INT = 0;
            
            SELECT @t_exists = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''%Date%'' OR name LIKE ''%Time%'';
            
            IF @t_exists > 0
            BEGIN
                SELECT @a_count = COUNT(DISTINCT c.name) 
                FROM ' + QUOTENAME(@DbName) + N'.sys.columns c 
                JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id 
                WHERE (t.name LIKE ''%Date%'' OR t.name LIKE ''%Time%'') 
                AND (c.name LIKE ''%Year%'' OR c.name LIKE ''%Month%'' OR c.name LIKE ''%Day%'' OR c.name LIKE ''%Quarter%'' OR c.name LIKE ''%Week%'');
            END

            SELECT 
                @p_Db, 
                CASE WHEN @a_count >= 4 THEN 3 WHEN @a_count BETWEEN 1 AND 3 THEN 2 WHEN @t_exists > 0 THEN 1 ELSE 0 END,
                CASE WHEN @t_exists = 0 THEN ''No Date/Time dimension table found'' ELSE ''Date table found. Matching attributes count: '' + CAST(@a_count AS NVARCHAR(10)) END;';

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