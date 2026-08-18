-- Checklist: Auto-scaling / serverless considered where workload is intermittent
-- Scope: DATABASE
-- Scoring: 3: Configured as Serverless or Auto-scaling. 2: Supports auto-pause/flexible scaling. 1: Provisioned low-tier. 0: Provisioned standard/premium or platform lacks support. NOTE: This script provides automated evidence. Full compliance requires human review of workload patterns.

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
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = ''Not evaluated'';

    IF OBJECT_ID(''sys.database_service_objectives'') IS NOT NULL
    BEGIN
        SELECT TOP 1
            @DbScore = CASE
                WHEN edition = ''Serverless'' THEN 3
                WHEN service_objective LIKE ''%Serverless%'' THEN 3
                WHEN service_objective LIKE ''%AutoScale%'' THEN 3
                WHEN edition = ''Basic'' THEN 1
                ELSE 0
            END,
            @DbFinding = ''Edition: '' + ISNULL(edition, ''Unknown'') + '', Service Objective: '' + ISNULL(service_objective, ''Unknown'')
        FROM sys.database_service_objectives;
    END
    ELSE
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''sys.database_service_objectives not available'';
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
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
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = ''Not evaluated'';

            IF OBJECT_ID(''sys.database_service_objectives'') IS NOT NULL
            BEGIN
                SELECT TOP 1
                    @DbScore = CASE
                        WHEN edition = ''Serverless'' THEN 3
                        WHEN service_objective LIKE ''%Serverless%'' THEN 3
                        WHEN service_objective LIKE ''%AutoScale%'' THEN 3
                        WHEN edition = ''Basic'' THEN 1
                        ELSE 0
                    END,
                    @DbFinding = ''Edition: '' + ISNULL(edition, ''Unknown'') + '', Service Objective: '' + ISNULL(service_objective, ''Unknown'')
                FROM sys.database_service_objectives;
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''Not an Azure SQL platform'';
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
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