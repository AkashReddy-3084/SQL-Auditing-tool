-- Checklist: Rollback / recovery procedure defined and tested
-- Scope: DATABASE
-- Scoring: 0: No rollback/recovery procedures found. 1: Procedures found but no testing evidence. 2: Procedures found with testing evidence/comments. 3: Not achievable (proxy check capped at 2).
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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    DECLARE @ProcCount INT = 0;
    DECLARE @TestedCount INT = 0;
    DECLARE @ProcNames NVARCHAR(MAX) = '';
    DECLARE @TestedNames NVARCHAR(MAX) = '';

    SELECT @ProcCount = COUNT(*)
    FROM sys.procedures p
    WHERE p.is_ms_shipped = 0
      AND (p.name LIKE '%rollback%' OR p.name LIKE '%recovery%' OR p.name LIKE '%undo%' OR p.name LIKE '%downgrade%' OR p.name LIKE '%revert%');

    IF @ProcCount > 0
    BEGIN
        SELECT @ProcNames = ISNULL(STRING_AGG(p.name, ', '), 'None')
        FROM sys.procedures p
        WHERE p.is_ms_shipped = 0
          AND (p.name LIKE '%rollback%' OR p.name LIKE '%recovery%' OR p.name LIKE '%undo%' OR p.name LIKE '%downgrade%' OR p.name LIKE '%revert%');

        SELECT @TestedCount = COUNT(*)
        FROM sys.extended_properties ep
        JOIN sys.procedures p ON ep.major_id = p.object_id
        WHERE ep.name IN ('Tested', 'Verified', 'LastTested')
          AND p.is_ms_shipped = 0
          AND (p.name LIKE '%rollback%' OR p.name LIKE '%recovery%' OR p.name LIKE '%undo%' OR p.name LIKE '%downgrade%' OR p.name LIKE '%revert%');

        IF @TestedCount > 0
        BEGIN
            SELECT @TestedNames = ISNULL(STRING_AGG(p.name, ', '), 'None')
            FROM sys.extended_properties ep
            JOIN sys.procedures p ON ep.major_id = p.object_id
            WHERE ep.name IN ('Tested', 'Verified', 'LastTested')
              AND p.is_ms_shipped = 0
              AND (p.name LIKE '%rollback%' OR p.name LIKE '%recovery%' OR p.name LIKE '%undo%' OR p.name LIKE '%downgrade%' OR p.name LIKE '%revert%');
        END
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        @DbName,
        CASE
            WHEN @ProcCount = 0 THEN 0
            WHEN @TestedCount = 0 THEN 1
            ELSE 2
        END,
        CASE
            WHEN @ProcCount = 0 THEN 'No rollback/recovery procedures found'
            WHEN @TestedCount = 0 THEN 'Found ' + CAST(@ProcCount AS NVARCHAR) + ' procedure(s): ' + @ProcNames + ' (no testing evidence)'
            ELSE 'Found ' + CAST(@ProcCount AS NVARCHAR) + ' procedure(s): ' + @ProcNames + ' | Tested: ' + @TestedNames
        END
    );
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
            DECLARE @ProcCount INT = 0;
            DECLARE @TestedCount INT = 0;
            DECLARE @ProcNames NVARCHAR(MAX) = '';
            DECLARE @TestedNames NVARCHAR(MAX) = '';

            SELECT @ProcCount = COUNT(*)
            FROM sys.procedures p
            WHERE p.is_ms_shipped = 0
              AND (p.name LIKE ''%rollback%'' OR p.name LIKE ''%recovery%'' OR p.name LIKE ''%undo%'' OR p.name LIKE ''%downgrade%'' OR p.name LIKE ''%revert%'');

            IF @ProcCount > 0
            BEGIN
                SELECT @ProcNames = ISNULL(STRING_AGG(p.name, '', ''), ''None'')
                FROM sys.procedures p
                WHERE p.is_ms_shipped = 0
                  AND (p.name LIKE ''%rollback%'' OR p.name LIKE ''%recovery%'' OR p.name LIKE ''%undo%'' OR p.name LIKE ''%downgrade%'' OR p.name LIKE ''%revert%'');

                SELECT @TestedCount = COUNT(*)
                FROM sys.extended_properties ep
                JOIN sys.procedures p ON ep.major_id = p.object_id
                WHERE ep.name IN (''Tested'', ''Verified'', ''LastTested'')
                  AND p.is_ms_shipped = 0
                  AND (p.name LIKE ''%rollback%'' OR p.name LIKE ''%recovery%'' OR p.name LIKE ''%undo%'' OR p.name LIKE ''%downgrade%'' OR p.name LIKE ''%revert%'');

                IF @TestedCount > 0
                BEGIN
                    SELECT @TestedNames = ISNULL(STRING_AGG(p.name, '', ''), ''None'')
                    FROM sys.extended_properties ep
                    JOIN sys.procedures p ON ep.major_id = p.object_id
                    WHERE ep.name IN (''Tested'', ''Verified'', ''LastTested'')
                      AND p.is_ms_shipped = 0
                      AND (p.name LIKE ''%rollback%'' OR p.name LIKE ''%recovery%'' OR p.name LIKE ''%undo%'' OR p.name LIKE ''%downgrade%'' OR p.name LIKE ''%revert%'');
                END
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + @DbName + ''',
                CASE
                    WHEN @ProcCount = 0 THEN 0
                    WHEN @TestedCount = 0 THEN 1
                    ELSE 2
                END,
                CASE
                    WHEN @ProcCount = 0 THEN ''No rollback/recovery procedures found''
                    WHEN @TestedCount = 0 THEN ''Found '' + CAST(@ProcCount AS