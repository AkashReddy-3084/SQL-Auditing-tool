-- Checklist: Row-Level Security implemented where multi-tenant/segmented access is required
-- Scope: DATABASE
-- Scoring: 0: No RLS predicates found. 1: 1-2 tables with RLS. 2: 3+ tables with RLS. (Capped at 2 as business requirements require human validation)

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    SELECT 
        DbName = ''' + REPLACE(@DbName, '''', '''''') + ''',
        DbScore = CASE 
            WHEN COUNT(DISTINCT o.object_id) = 0 THEN 0
            WHEN COUNT(DISTINCT o.object_id) <= 2 THEN 1
            ELSE 2
        END,
        Finding = CASE 
            WHEN COUNT(DISTINCT o.object_id) = 0 THEN ''No RLS predicates found''
            ELSE STRING_AGG(DISTINCT s.name + ''.'' + o.name, '', '') WITHIN GROUP (ORDER BY s.name, o.name)
        END
    FROM sys.security_predicates sp
    JOIN sys.objects o ON sp.major_id = o.object_id
    JOIN sys.schemas s ON o.schema_id = s.schema_id
    WHERE o.type = ''U'';';
    
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            SELECT 
                DbName = ''' + REPLACE(@DbName, '''', '''''') + ''',
                DbScore = CASE 
                    WHEN COUNT(DISTINCT o.object_id) = 0 THEN 0
                    WHEN COUNT(DISTINCT o.object_id) <= 2 THEN 1
                    ELSE 2
                END,
                Finding = CASE 
                    WHEN COUNT(DISTINCT o.object_id) = 0 THEN ''No RLS predicates found''
                    ELSE STRING_AGG(DISTINCT s.name + ''.'' + o.name, '', '') WITHIN GROUP (ORDER BY s.name, o.name)
                END
            FROM sys.security_predicates sp
            JOIN sys.objects o ON sp.major_id = o.object_id
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE o.type = ''U'';';
            
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'No user databases found');

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @Finding = ISNULL(
    (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
    'No non-compliant findings found'
);

SET @Finding = @Finding + CHAR(13) + CHAR(10) + '-- NOTE: This script provides automated evidence. Full compliance requires human review.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;