-- Checklist: Deadlock-prone patterns avoided; retry logic where needed
-- Scope: DATABASE
-- Scoring: 3=All transactional procedures implement TRY/CATCH error handling; 2=Most have proper handling with minor gaps; 1=Some lack error handling/retry logic; 0=Many procedures use transactions without proper error handling or retry mechanisms.
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
    SET @Sql = N'
    DECLARE @TotalTrans INT = 0;
    DECLARE @WithTryCatch INT = 0;
    DECLARE @NonCompliant NVARCHAR(MAX) = '''';

    SELECT @TotalTrans = COUNT(*)
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE m.definition LIKE ''%BEGIN TRAN%'' OR m.definition LIKE ''%BEGIN TRANSACTION%'';

    SELECT @WithTryCatch = COUNT(*)
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE (m.definition LIKE ''%BEGIN TRAN%'' OR m.definition LIKE ''%BEGIN TRANSACTION%'')
      AND m.definition LIKE ''%TRY%''
      AND m.definition LIKE ''%CATCH%'';

    IF @TotalTrans > 0
    BEGIN
        SELECT @NonCompliant = STRING_AGG(p.name, '', '')
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE (m.definition LIKE ''%BEGIN TRAN%'' OR m.definition LIKE ''%BEGIN TRANSACTION%'')
          AND (m.definition NOT LIKE ''%TRY%'' OR m.definition NOT LIKE ''%CATCH%'');
    END

    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    IF @TotalTrans = 0
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''No transactional procedures found'';
    END
    ELSE IF @WithTryCatch = @TotalTrans
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''All '' + CAST(@TotalTrans AS NVARCHAR) + '' transactional procedures implement TRY/CATCH error handling'';
    END
    ELSE IF CAST(@WithTryCatch AS FLOAT) / @TotalTrans >= 0.8
    BEGIN
        SET @DbScore = 2;
        SET @DbFinding = ''Most procedures have error handling. Non-compliant: '' + ISNULL(@NonCompliant, ''None'');
    END
    ELSE IF CAST(@WithTryCatch AS FLOAT) / @TotalTrans >= 0.5
    BEGIN
        SET @DbScore = 1;
        SET @DbFinding = ''Some procedures lack error handling. Non-compliant: '' + ISNULL(@NonCompliant, ''None'');
    END
    ELSE
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''Many procedures lack error handling. Non-compliant: '' + ISNULL(@NonCompliant, ''None'');
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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
            DECLARE @TotalTrans INT = 0;
            DECLARE @WithTryCatch INT = 0;
            DECLARE @NonCompliant NVARCHAR(MAX) = '''';

            SELECT @TotalTrans = COUNT(*)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE m.definition LIKE ''%BEGIN TRAN%'' OR m.definition LIKE ''%BEGIN TRANSACTION%'';

            SELECT @WithTryCatch = COUNT(*)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE (m.definition LIKE ''%BEGIN TRAN%'' OR m.definition LIKE ''%BEGIN TRANSACTION%'')
              AND m.definition LIKE ''%TRY%''
              AND m.definition LIKE ''%CATCH%'';

            IF @TotalTrans > 0
            BEGIN
                SELECT @NonCompliant = STRING_AGG(p.name, '', '')
                FROM sys.procedures p
                JOIN sys.sql_modules m ON p.object_id = m.object_id
                WHERE (m.definition LIKE ''%BEGIN TRAN%'' OR m.definition LIKE ''%BEGIN TRANSACTION%'')
                  AND (m.definition NOT LIKE ''%TRY%'' OR m.definition NOT LIKE ''%CATCH%'');
            END

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @TotalTrans = 0
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''No transactional procedures found'';
            END
            ELSE IF @WithTryCatch = @TotalTrans
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''All '' + CAST(@TotalTrans AS NVARCHAR) + '' transactional procedures implement TRY/CATCH error handling'';
            END
            ELSE IF CAST(@WithTryCatch AS FLOAT) / @TotalTrans >= 0.8
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''Most procedures have error handling. Non-compliant: '' + ISNULL(@NonCompliant, ''None'');
            END
            ELSE IF CAST(@WithTryCatch AS FLOAT) / @TotalTrans >= 0.5
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = ''Some procedures lack error handling. Non-compliant: '' + ISNULL(@NonCompliant, ''None'');
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''Many procedures lack error handling. Non-compliant: '' + ISNULL(@NonCompliant, ''None'');
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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