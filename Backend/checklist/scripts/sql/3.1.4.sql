-- Checklist: SET NOCOUNT ON and appropriate SET options in procedures
-- Scope: DATABASE
-- Scoring: 3 = 100% compliant; 2 = >80% compliant; 1 = >50% compliant; 0 = <=50% compliant

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Sql = N'
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT DB_NAME(),
           CASE 
               WHEN COUNT(*) = 0 THEN 3 
               WHEN SUM(CASE WHEN m.definition LIKE ''%SET NOCOUNT ON%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) = 1.0 THEN 3
               WHEN SUM(CASE WHEN m.definition LIKE ''%SET NOCOUNT ON%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) > 0.8 THEN 2
               WHEN SUM(CASE WHEN m.definition LIKE ''%SET NOCOUNT ON%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) > 0.5 THEN 1
               ELSE 0 
           END,
           CASE 
               WHEN COUNT(*) = 0 THEN ''No procedures found''
               ELSE ''Non-compliant procedures: '' + ISNULL(STRING_AGG(CASE WHEN m.definition NOT LIKE ''%SET NOCOUNT ON%'' THEN QUOTENAME(s.name) + ''.'' + QUOTENAME(p.name) END, '', ''), ''None'')
           END
    FROM sys.procedures AS p
    JOIN sys.schemas AS s ON s.schema_id = p.schema_id
    JOIN sys.sql_modules AS m ON m.object_id = p.object_id;';
    EXEC sp_executesql @Sql;
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
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT ' + QUOTENAME(@DbName, '''') + N',
                CASE 
                    WHEN COUNT(*) = 0 THEN 3 
                    WHEN SUM(CASE WHEN m.definition LIKE ''%SET NOCOUNT ON%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) = 1.0 THEN 3
                    WHEN SUM(CASE WHEN m.definition LIKE ''%SET NOCOUNT ON%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) > 0.8 THEN 2
                    WHEN SUM(CASE WHEN m.definition LIKE ''%SET NOCOUNT ON%'' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0) > 0.5 THEN 1
                    ELSE 0 
                END,
                CASE 
                    WHEN COUNT(*) = 0 THEN ''No procedures found''
                    ELSE ''Non-compliant procedures: '' + ISNULL(STRING_AGG(CASE WHEN m.definition NOT LIKE ''%SET NOCOUNT ON%'' THEN QUOTENAME(s.name) + ''.'' + QUOTENAME(p.name) END, '', ''), ''None'')
                END
                FROM ' + QUOTENAME(@DbName) + N'.sys.procedures AS p
                JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = p.schema_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m ON m.object_id = p.object_id;';

            EXEC sp_executesql @Sql;
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

SELECT @DatabaseQueried = ISNULL(STRING_AGG(DbName, ', '), 'None') FROM #DbResults;
SELECT @Score = ISNULL(MIN(DbScore), 0) FROM #DbResults;
SELECT @Finding = ISNULL(STRING_AGG(DbName + ': ' + Finding, '; '), 'No database found to be queried') FROM #DbResults;

IF @DatabaseQueried = 'None'
BEGIN
    SET @Score = 0;
    SET @Finding = 'No database found to be queried';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;