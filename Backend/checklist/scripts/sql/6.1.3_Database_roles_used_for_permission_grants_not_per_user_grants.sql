-- Checklist: Database roles used for permission grants (not per-user grants)
-- Scope: DATABASE
-- Scoring: 3: 0 direct grants to users. 2: 1-3 direct grants. 1: 4-10 direct grants. 0: >10 direct grants.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
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
    DECLARE @CurrentDbName NVARCHAR(128) = DB_NAME();
    DECLARE @Count INT;
    DECLARE @Violations NVARCHAR(MAX);

    SELECT @Count = COUNT(*)
    FROM sys.database_permissions dp
    JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
    WHERE p.type IN ('S', 'U', 'X');

    SELECT @Violations = STRING_AGG(p.name + ' (' + dp.permission_name + ')', ', ')
    FROM sys.database_permissions dp
    JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
    WHERE p.type IN ('S', 'U', 'X');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        @CurrentDbName,
        CASE 
            WHEN @Count = 0 THEN 3
            WHEN @Count <= 3 THEN 2
            WHEN @Count <= 10 THEN 1
            ELSE 0
        END,
        ISNULL(@Violations, 'No direct user grants found')
    );
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate all online user databases
    DECLARE @DbName NVARCHAR(256);
    DECLARE @Sql NVARCHAR(MAX);

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
            DECLARE @Count INT;
            DECLARE @Violations NVARCHAR(MAX);
            SELECT @Count = COUNT(*)
            FROM sys.database_permissions dp
            JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
            WHERE p.type IN (''S'', ''U'', ''X'');

            SELECT @Violations = STRING_AGG(p.name + '' ('' + dp.permission_name + '')'', '', '')
            FROM sys.database_permissions dp
            JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
            WHERE p.type IN (''S'', ''U'', ''X'');

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', 
                CASE WHEN @Count = 0 THEN 3 WHEN @Count <= 3 THEN 2 WHEN @Count <= 10 THEN 1 ELSE 0 END, 
                ISNULL(@Violations, ''No direct user grants found''));';
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

-- Aggregate results across evaluated databases
SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'No user databases found');
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