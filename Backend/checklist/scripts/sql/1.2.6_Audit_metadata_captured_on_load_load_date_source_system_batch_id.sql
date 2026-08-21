-- Checklist: Audit metadata captured on load (load_date, source_system, batch_id)
-- Scope: DATABASE
-- Scoring: 0: 0% of user tables contain audit columns. 1: 1-24% contain audit columns. 2: 25-74% contain audit columns. 3: >=75% contain audit columns.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    
    DECLARE @TotalTables INT;
    DECLARE @AuditTables INT;
    DECLARE @Pct DECIMAL(5,2);
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    SELECT @TotalTables = COUNT(*) 
    FROM sys.tables 
    WHERE type_desc = 'USER_TABLE';

    SELECT @AuditTables = COUNT(DISTINCT t.object_id)
    FROM sys.tables t
    JOIN sys.columns c ON t.object_id = c.object_id
    WHERE t.type_desc = 'USER_TABLE'
      AND LOWER(c.name) IN ('load_date', 'source_system', 'batch_id');

    IF @TotalTables = 0 
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = 'No user tables found; audit metadata check skipped.';
    END 
    ELSE 
    BEGIN
        SET @Pct = (@AuditTables * 100.0) / @TotalTables;
        IF @Pct >= 75 SET @DbScore = 3;
        ELSE IF @Pct >= 25 SET @DbScore = 2;
        ELSE IF @Pct > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        SET @DbFinding = CAST(@AuditTables AS NVARCHAR) + ' of ' + CAST(@TotalTables AS NVARCHAR) + ' user tables (' + CAST(@Pct AS NVARCHAR) + '%) contain audit metadata columns (load_date, source_system, batch_id).';
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@DbName, @DbScore, @DbFinding);
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate all online user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TotalTables INT;
            DECLARE @AuditTables INT;
            DECLARE @Pct DECIMAL(5,2);
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type_desc = ''USER_TABLE'';
            
            SELECT @AuditTables = COUNT(DISTINCT t.object_id)
            FROM sys.tables t
            JOIN sys.columns c ON t.object_id = c.object_id
            WHERE t.type_desc = ''USER_TABLE''
              AND LOWER(c.name) IN (''load_date'', ''source_system'', ''batch_id'');

            IF @TotalTables = 0 BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''No user tables found; audit metadata check skipped.'';
            END ELSE BEGIN
                SET @Pct = (@AuditTables * 100.0) / @TotalTables;
                IF @Pct >= 75 SET @DbScore = 3;
                ELSE IF @Pct >= 25 SET @DbScore = 2;
                ELSE IF @Pct > 0 SET @DbScore = 1;
                ELSE SET @DbScore = 0;
                SET @DbFinding = CAST(@AuditTables AS NVARCHAR) + '' of '' + CAST(@TotalTables AS NVARCHAR) + '' user tables ('' + CAST(@Pct AS NVARCHAR) + ''%) contain audit metadata columns (load_date, source_system, batch_id).'';
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed: ' + ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;