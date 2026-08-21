-- Checklist: Lock escalation understood and mitigated where problematic
-- Scope: DATABASE
-- Scoring: 0: No tables have lock escalation explicitly disabled or partitioned. 1: 1-5 tables configured. 2: 6-20 tables configured. 3: >20 tables configured.

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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @Count INT;
    DECLARE @Names NVARCHAR(MAX);
    SELECT @Count = COUNT(*), @Names = STRING_AGG(name, ' ', '')
    FROM sys.tables
    WHERE lock_escalation_option <> 0;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        @pDbName,
        CASE 
            WHEN @Count = 0 THEN 0
            WHEN @Count BETWEEN 1 AND 5 THEN 1
            WHEN @Count BETWEEN 6 AND 20 THEN 2
            ELSE 3
        END,
        ISNULL(@Names, ''''No tables with lock escalation mitigation found'''')
    );
    ';
    EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @Count INT;
            DECLARE @Names NVARCHAR(MAX);
            SELECT @Count = COUNT(*), @Names = STRING_AGG(name, ' ', '')
            FROM sys.tables
            WHERE lock_escalation_option <> 0;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                @pDbName,
                CASE 
                    WHEN @Count = 0 THEN 0
                    WHEN @Count BETWEEN 1 AND 5 THEN 1
                    WHEN @Count BETWEEN 6 AND 20 THEN 2
                    ELSE 3
                END,
                ISNULL(@Names, ''''No tables with lock escalation mitigation found'''')
            );
            ';
            EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
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

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;