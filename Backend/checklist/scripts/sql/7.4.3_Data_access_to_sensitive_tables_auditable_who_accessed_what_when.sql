-- Checklist: Data access to sensitive tables auditable (who accessed what, when)
-- Scope: DATABASE
-- Scoring: 0=No audit spec; 1=Spec exists but disabled; 2=Spec enabled but no data access coverage; 3=Spec enabled and covers SELECT/INSERT/UPDATE/DELETE on tables.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

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

IF @IsAzureSQLDB = 1
BEGIN
    -- Azure SQL Database: Evaluate only current database
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @DbScore INT = 0;
        DECLARE @DbFinding NVARCHAR(MAX) = ''No audit specification configured.'';

        IF EXISTS (SELECT 1 FROM sys.database_audit_specifications)
        BEGIN
            IF EXISTS (
                SELECT 1
                FROM sys.database_audit_specifications s
                JOIN sys.database_audit_specification_details d ON s.name = d.audit_specification_name
                JOIN sys.dm_audit_actions a ON d.audit_action_id = a.action_id
                WHERE s.is_state_enabled = 1
                  AND a.action_name IN (''SELECT'', ''INSERT'', ''UPDATE'', ''DELETE'')
            )
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''Audit enabled covering data access (SELECT/INSERT/UPDATE/DELETE) on tables.'';
            END
            ELSE IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE is_state_enabled = 1)
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''Audit enabled but does not explicitly cover data access on tables.'';
            END
            ELSE
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = ''Audit specification exists but is disabled.'';
            END
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
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
            DECLARE @DbFinding NVARCHAR(MAX) = ''No audit specification configured.'';

            IF EXISTS (SELECT 1 FROM sys.database_audit_specifications)
            BEGIN
                IF EXISTS (
                    SELECT 1
                    FROM sys.database_audit_specifications s
                    JOIN sys.database_audit_specification_details d ON s.name = d.audit_specification_name
                    JOIN sys.dm_audit_actions a ON d.audit_action_id = a.action_id
                    WHERE s.is_state_enabled = 1
                      AND a.action_name IN (''SELECT'', ''INSERT'', ''UPDATE'', ''DELETE'')
                )
                BEGIN
                    SET @DbScore = 3;
                    SET @DbFinding = ''Audit enabled covering data access (SELECT/INSERT/UPDATE/DELETE) on tables.'';
                END
                ELSE IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE is_state_enabled = 1)
                BEGIN
                    SET @DbScore = 2;
                    SET @DbFinding = ''Audit enabled but does not explicitly cover data access on tables.'';
                END
                ELSE
                BEGIN
                    SET @DbScore = 1;
                    SET @DbFinding = ''Audit specification exists but is disabled.'';
                END
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