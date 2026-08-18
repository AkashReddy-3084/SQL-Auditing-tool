-- Checklist: Audit columns present where needed (created/modified, source, batch)
-- Scope: DATABASE
-- Scoring: 0: >30% of user tables lack audit columns. 1: 10-30% lack audit columns. 2: <=10% lack audit columns. 3: 0% lack audit columns (all tables have at least one recognized audit column).
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current connected database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @TotalTables INT;
        DECLARE @TablesWithAudit INT;
        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
        SELECT @TablesWithAudit = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        JOIN sys.columns c ON t.object_id = c.object_id
        WHERE t.type = ''U''
          AND (c.name LIKE ''created%'' OR c.name LIKE ''modified%'' OR c.name LIKE ''updated%'' OR c.name LIKE ''source%'' OR c.name LIKE ''batch%'' OR c.name LIKE ''load_date%'' OR c.name LIKE ''inserted%'');
        
        DECLARE @MissingPct FLOAT = CASE WHEN @TotalTables = 0 THEN 0 ELSE CAST(@TotalTables - @TablesWithAudit AS FLOAT) / @TotalTables * 100 END;
        DECLARE @DbScore INT = CASE 
            WHEN @MissingPct = 0 THEN 3
            WHEN @MissingPct <= 10 THEN 2
            WHEN @MissingPct <= 30 THEN 1
            ELSE 0
        END;
        
        DECLARE @Finding NVARCHAR(MAX) = ''Total tables: '' + CAST(@TotalTables AS NVARCHAR(10)) + '', '' + CAST(@TablesWithAudit AS NVARCHAR(10)) + '' have audit columns ('' + CAST(@MissingPct AS NVARCHAR(10)) + ''% missing).'';
        
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @Finding);
    ';
    EXEC sp_executesql @Sql;
    SET @DatabaseQueried = @DbName;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate all online user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
                DECLARE @TotalTables INT;
                DECLARE @TablesWithAudit INT;
                SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
                SELECT @TablesWithAudit = COUNT(DISTINCT t.object_id)
                FROM sys.tables t
                JOIN sys.columns c ON t.object_id = c.object_id
                WHERE t.type = ''U''
                  AND (c.name LIKE ''created%'' OR c.name LIKE ''modified%'' OR c.name LIKE ''updated%'' OR c.name LIKE ''source%'' OR c.name LIKE ''batch%'' OR c.name LIKE ''load_date%'' OR c.name LIKE ''inserted%'');
                
                DECLARE @MissingPct FLOAT = CASE WHEN @TotalTables = 0 THEN 0 ELSE CAST(@TotalTables - @TablesWithAudit AS FLOAT) / @TotalTables * 100 END;
                DECLARE @DbScore INT = CASE 
                    WHEN @MissingPct = 0 THEN 3
                    WHEN @MissingPct <= 10 THEN 2
                    WHEN @MissingPct <= 30 THEN 1
                    ELSE 0
                END;
                
                DECLARE @Finding NVARCHAR(MAX) = ''Total tables: '' + CAST(@TotalTables AS NVARCHAR(10)) + '', '' + CAST(@TablesWithAudit AS NVARCHAR(10)) + '' have audit columns ('' + CAST(@MissingPct AS NVARCHAR(10)) + ''% missing).'';
                
                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @Finding);
            ';
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

    SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
END

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @Finding = ISNULL(
    (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;