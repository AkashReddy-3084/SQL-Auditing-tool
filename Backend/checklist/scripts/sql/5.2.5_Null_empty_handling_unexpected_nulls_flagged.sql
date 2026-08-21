-- Checklist: Null/empty handling: unexpected nulls flagged
-- Scope: DATABASE
-- Scoring: 3=All staging tables have explicit null/empty handling in ETL procedures/constraints; 2=Most (>=75%); 1=Some (>=25%); 0=None or <25%

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

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @StagingTables TABLE (FullName NVARCHAR(256));
    DECLARE @HandledTables TABLE (FullName NVARCHAR(256));
    DECLARE @TotalStaging INT = 0;
    DECLARE @HandledCount INT = 0;
    DECLARE @UncoveredTables NVARCHAR(MAX) = '';

    INSERT INTO @StagingTables
    SELECT SCHEMA_NAME(t.schema_id) + ''.'' + t.name
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%stage%''
       OR t.name LIKE ''stg_%'' OR t.name LIKE ''landing_%'' OR t.name LIKE ''%raw_%'' OR t.name LIKE ''%stage_%'';

    SET @TotalStaging = (SELECT COUNT(*) FROM @StagingTables);

    IF @TotalStaging > 0
    BEGIN
        INSERT INTO @HandledTables
        SELECT DISTINCT st.FullName
        FROM @StagingTables st
        JOIN sys.sql_expression_dependencies dep ON dep.referenced_id = OBJECT_ID(st.FullName)
        JOIN sys.procedures p ON dep.object_id = p.object_id
        JOIN sys.sql_modules sm ON p.object_id = sm.object_id
        WHERE sm.definition LIKE ''%IS NULL%'' OR sm.definition LIKE ''%= ''''%''''%'' OR sm.definition LIKE ''%LEN(%''''%''''%'' = 0%'' OR sm.definition LIKE ''%COALESCE%'' OR sm.definition LIKE ''%NULLIF%'';

        SET @HandledCount = (SELECT COUNT(*) FROM @HandledTables);

        SELECT @UncoveredTables = STRING_AGG(FullName, '', '')
        FROM @StagingTables
        WHERE FullName NOT IN (SELECT FullName FROM @HandledTables);
    END

    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    IF @TotalStaging = 0
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''No staging tables identified'';
    END
    ELSE
    BEGIN
        DECLARE @Coverage DECIMAL(5,2) = CAST(@HandledCount AS DECIMAL) / @TotalStaging * 100;
        SET @DbScore = CASE
            WHEN @Coverage >= 100 THEN 3
            WHEN @Coverage >= 75 THEN 2
            WHEN @Coverage >= 25 THEN 1
            ELSE 0
        END;
        SET @DbFinding = CAST(@HandledCount AS NVARCHAR) + '' of '' + CAST(@TotalStaging AS NVARCHAR) + '' staging tables have null/empty handling. Uncovered: '' + ISNULL(@UncoveredTables, ''None'');
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE -- SQL Server / Azure SQL MI
BEGIN
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
            DECLARE @StagingTables TABLE (FullName NVARCHAR(256));
            DECLARE @HandledTables TABLE (FullName NVARCHAR(256));
            DECLARE @TotalStaging INT = 0;
            DECLARE @HandledCount INT = 0;
            DECLARE @UncoveredTables NVARCHAR(MAX) = '';

            INSERT INTO @StagingTables
            SELECT SCHEMA_NAME(t.schema_id) + ''.'' + t.name
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%stage%''
               OR t.name LIKE ''stg_%'' OR t.name LIKE ''landing_%'' OR t.name LIKE ''%raw_%'' OR t.name LIKE ''%stage_%'';

            SET @TotalStaging = (SELECT COUNT(*) FROM @StagingTables);

            IF @TotalStaging > 0
            BEGIN
                INSERT INTO @HandledTables
                SELECT DISTINCT st.FullName
                FROM @StagingTables st
                JOIN sys.sql_expression_dependencies dep ON dep.referenced_id = OBJECT_ID(st.FullName)
                JOIN sys.procedures p ON dep.object_id = p.object_id
                JOIN sys.sql_modules sm ON p.object_id = sm.object_id
                WHERE sm.definition LIKE ''%IS NULL%'' OR sm.definition LIKE ''%= ''''%''''%'' OR sm.definition LIKE ''%LEN(%''''%''''%'' = 0%'' OR sm.definition LIKE ''%COALESCE%'' OR sm.definition LIKE ''%NULLIF%'';

                SET @HandledCount = (SELECT COUNT(*) FROM @HandledTables);

                SELECT @UncoveredTables = STRING_AGG(FullName, '', '')
                FROM @StagingTables
                WHERE FullName NOT IN (SELECT FullName FROM @HandledTables);
            END

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @TotalStaging = 0
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''No staging tables identified'';
            END
            ELSE
            BEGIN
                DECLARE @Coverage DECIMAL(5,2) = CAST(@HandledCount AS DECIMAL) / @TotalStaging * 100;
                SET @DbScore = CASE
                    WHEN @Coverage >= 100 THEN 3
                    WHEN @Coverage >= 75 THEN 2
                    WHEN @Coverage >= 25 THEN 1
                    ELSE 0
                END;
                SET @DbFinding = CAST(@HandledCount AS NVARCHAR) + '' of '' + CAST(@TotalStaging AS NVARCHAR) + '' staging tables have null/empty handling. Uncovered: '' + ISNULL(@UncoveredTables, ''None'');
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
        WHERE Finding IS NOT NULL AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result