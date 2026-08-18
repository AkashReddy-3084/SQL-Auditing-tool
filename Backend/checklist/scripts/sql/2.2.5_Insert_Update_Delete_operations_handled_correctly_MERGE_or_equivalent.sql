-- Checklist: Insert/Update/Delete operations handled correctly (MERGE or equivalent)
-- Scope: DATABASE
-- Scoring: 3=MERGE used, 2=Separate I/U/D used, 1=Partial DML, 0=No DML
-- NOTE: This script provides automated evidence. Full compliance requires human review of ETL logic.

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
    -- Azure SQL Database: Evaluate current connected database only
    SET @DbName = DB_NAME();
    
    DECLARE @MergeCount INT = 0;
    DECLARE @InsertCount INT = 0;
    DECLARE @UpdateCount INT = 0;
    DECLARE @DeleteCount INT = 0;

    SELECT
        @MergeCount = COUNT(CASE WHEN definition LIKE '%MERGE%' THEN 1 END),
        @InsertCount = COUNT(CASE WHEN definition LIKE '%INSERT%' THEN 1 END),
        @UpdateCount = COUNT(CASE WHEN definition LIKE '%UPDATE%' THEN 1 END),
        @DeleteCount = COUNT(CASE WHEN definition LIKE '%DELETE%' THEN 1 END)
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE p.is_ms_shipped = 0;

    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    IF @MergeCount > 0
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = 'MERGE statements detected in ' + CAST(@MergeCount AS NVARCHAR) + ' procedure(s).';
    END
    ELSE IF @InsertCount > 0 AND @UpdateCount > 0 AND @DeleteCount > 0
    BEGIN
        SET @DbScore = 2;
        SET @DbFinding = 'Separate INSERT, UPDATE, and DELETE operations detected.';
    END
    ELSE IF @InsertCount > 0 OR @UpdateCount > 0 OR @DeleteCount > 0
    BEGIN
        SET @DbScore = 1;
        SET @DbFinding = 'Partial DML operations detected.';
    END
    ELSE
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = 'No Insert/Update/Delete operations found in stored procedures.';
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@DbName, @DbScore, @DbFinding);
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate through online user databases
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
            DECLARE @MergeCount INT = 0;
            DECLARE @InsertCount INT = 0;
            DECLARE @UpdateCount INT = 0;
            DECLARE @DeleteCount INT = 0;

            SELECT
                @MergeCount = COUNT(CASE WHEN definition LIKE ''%MERGE%'' THEN 1 END),
                @InsertCount = COUNT(CASE WHEN definition LIKE ''%INSERT%'' THEN 1 END),
                @UpdateCount = COUNT(CASE WHEN definition LIKE ''%UPDATE%'' THEN 1 END),
                @DeleteCount = COUNT(CASE WHEN definition LIKE ''%DELETE%'' THEN 1 END)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE p.is_ms_shipped = 0;

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @MergeCount > 0
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''MERGE statements detected in '' + CAST(@MergeCount AS NVARCHAR) + '' procedure(s).'';
            END
            ELSE IF @InsertCount > 0 AND @UpdateCount > 0 AND @DeleteCount > 0
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''Separate INSERT, UPDATE, and DELETE operations detected.''
            END
            ELSE IF @InsertCount > 0 OR @UpdateCount > 0 OR @DeleteCount > 0
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = ''Partial DML operations detected.''
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''No Insert/Update/Delete operations found in stored procedures.''
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, @DbFinding);';

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