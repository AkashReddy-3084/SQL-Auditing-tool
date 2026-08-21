-- Checklist: Every table/dataset has a defined data owner
-- Scope: DATABASE
-- Scoring: 3=All tables have owner; 2=>90% have owner; 1=>50% have owner; 0=<=50% have owner

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DbName NVARCHAR(128);
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
    -- Azure SQL Database: Evaluate current connected database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @TotalTables INT;
        DECLARE @TablesWithOwner INT;
        DECLARE @MissingTables NVARCHAR(MAX);

        SELECT @TotalTables = COUNT(*) FROM sys.tables;

        SELECT @TablesWithOwner = COUNT(*)
        FROM sys.tables t
        INNER JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.class = 1
        WHERE ep.name IN (''DataOwner'', ''Owner'', ''Data_Owner'', ''data_owner'', ''owner'');

        SELECT @MissingTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
        FROM sys.tables t
        LEFT JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.class = 1
            AND ep.name IN (''DataOwner'', ''Owner'', ''Data_Owner'', ''data_owner'', ''owner'')
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE ep.name IS NULL;

        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);

        IF @TotalTables = 0
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = ''No tables found'';
        END
        ELSE
        BEGIN
            IF @TablesWithOwner = @TotalTables
                SET @DbScore = 3;
            ELSE IF CAST(@TablesWithOwner AS FLOAT) / @TotalTables >= 0.9
                SET @DbScore = 2;
            ELSE IF CAST(@TablesWithOwner AS FLOAT) / @TotalTables >= 0.5
                SET @DbScore = 1;
            ELSE
                SET @DbScore = 0;

            SET @DbFinding = ISNULL(@MissingTables, ''No non-compliant objects found'');
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate all online user databases
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
            DECLARE @TotalTables INT;
            DECLARE @TablesWithOwner INT;
            DECLARE @MissingTables NVARCHAR(MAX);

            SELECT @TotalTables = COUNT(*) FROM sys.tables;

            SELECT @TablesWithOwner = COUNT(*)
            FROM sys.tables t
            INNER JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.class = 1
            WHERE ep.name IN (''DataOwner'', ''Owner'', ''Data_Owner'', ''data_owner'', ''owner'');

            SELECT @MissingTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
            FROM sys.tables t
            LEFT JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.class = 1
                AND ep.name IN (''DataOwner'', ''Owner'', ''Data_Owner'', ''data_owner'', ''owner'')
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE ep.name IS NULL;

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @TotalTables = 0
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''No tables found'';
            END
            ELSE
            BEGIN
                IF @TablesWithOwner = @TotalTables
                    SET @DbScore = 3;
                ELSE IF CAST(@TablesWithOwner AS FLOAT) / @TotalTables >= 0.9
                    SET @DbScore = 2;
                ELSE IF CAST(@TablesWithOwner AS FLOAT) / @TotalTables >= 0.5
                    SET @DbScore = 1;
                ELSE
                    SET @DbScore = 0;

                SET @DbFinding = ISNULL(@MissingTables, ''No non-compliant objects found'');
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore, @DbFinding);
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