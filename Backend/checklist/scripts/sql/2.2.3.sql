-- Checklist: Watermark/control values persisted reliably (control table, not volatile)
-- Scope: DATABASE
-- Scoring: 3 = persistent control tables found; 2 = minimal evidence (1 table); 1 = naming patterns found but no clear control table; 0 = no evidence of watermark persistence.

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
                WHEN COUNT(*) >= 2 THEN 3 
                WHEN COUNT(*) = 1 THEN 2 
                ELSE 0 
           END,
           CASE 
                WHEN COUNT(*) >= 1 THEN 'Found persistent control tables: ' + STRING_AGG(QUOTENAME(s.name) + '.' + QUOTENAME(t.name), ', ')
                ELSE 'No persistent watermark/control tables found' 
           END
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.name LIKE '%control%' OR t.name LIKE '%watermark%' OR t.name LIKE '%load_stat%' OR t.name LIKE '%audit_log%';
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
                    WHEN COUNT(*) >= 2 THEN 3 
                    WHEN COUNT(*) = 1 THEN 2 
                    ELSE 0 
                END,
                CASE 
                    WHEN COUNT(*) >= 1 THEN ''Found persistent control tables: '' + STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name), '', '')
                    ELSE ''No persistent watermark/control tables found'' 
                END
                FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
                JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
                WHERE t.name LIKE ''%control%'' OR t.name LIKE ''%watermark%'' OR t.name LIKE ''%load_stat%'' OR t.name LIKE ''%audit_log%'';';

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