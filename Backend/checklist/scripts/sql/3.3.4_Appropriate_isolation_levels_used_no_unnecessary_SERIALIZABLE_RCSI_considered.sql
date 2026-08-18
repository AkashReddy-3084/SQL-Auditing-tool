-- Checklist: Appropriate isolation levels used (no unnecessary SERIALIZABLE; RCSI considered)
-- Scope: DATABASE
-- Scoring: 3: RCSI is ON. 2: RCSI is OFF, no explicit SERIALIZABLE found. 1: RCSI is OFF, explicit SERIALIZABLE found. 0: Evaluation failed.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQLDB = 1
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Pending evaluation');

    BEGIN TRY
        DECLARE @RCSI BIT;
        DECLARE @SeriazCount INT = 0;

        SET @RCSI = CONVERT(BIT, DATABASEPROPERTYEX(DB_NAME(), 'IsReadCommittedSnapshotOn'));

        IF @RCSI = 0
        BEGIN
            SELECT @SeriazCount = COUNT(*) FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN ('P','V','FN','IF','TF')
              AND m.definition LIKE '%SET TRANSACTION ISOLATION LEVEL SERIALIZABLE%';
        END

        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);

        IF @RCSI = 1
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = 'RCSI is enabled.';
        END
        ELSE IF @SeriazCount = 0
        BEGIN
            SET @DbScore = 2;
            SET @DbFinding = 'RCSI is disabled. No explicit SERIALIZABLE isolation level found in procedures.';
        END
        ELSE
        BEGIN
            SET @DbScore = 1;
            SET @DbFinding = 'RCSI is disabled. ' + CAST(@SeriazCount AS NVARCHAR(10)) + ' procedure(s) use SERIALIZABLE isolation level.';
        END

        UPDATE #DbResults SET DbScore = @DbScore, Finding = @DbFinding WHERE DbName = @DbName;
    END TRY
    BEGIN CATCH
        UPDATE #DbResults SET DbScore = 0, Finding = 'Database evaluation failed: ' + ERROR_MESSAGE() WHERE DbName = @DbName;
    END CATCH;
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
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Pending evaluation');

        BEGIN TRY
            DECLARE @RCSI BIT;
            DECLARE @SeriazCount INT = 0;

            SELECT @RCSI = is_read_committed_snapshot_on FROM sys.databases WHERE database_id = DB_ID(@DbName);

            IF @RCSI = 0
            BEGIN
                SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
                SELECT @SeriazCount = COUNT(*) FROM sys.sql_modules m
                JOIN sys.objects o ON m.object_id = o.object_id
                WHERE o.type IN (''P'',''V'',''FN'',''IF'',''TF'')
                  AND m.definition LIKE ''%SET TRANSACTION ISOLATION LEVEL SERIALIZABLE%'';';
                EXEC sp_executesql @Sql, N'@SeriazCount INT OUTPUT', @SeriazCount OUTPUT;
            END

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @RCSI = 1
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = 'RCSI is enabled.';
            END
            ELSE IF @SeriazCount = 0
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = 'RCSI is disabled. No explicit SERIALIZABLE isolation level found in procedures.';
            END
            ELSE
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = 'RCSI is disabled. ' + CAST(@SeriazCount AS NVARCHAR(10)) + ' procedure(s) use SERIALIZABLE isolation level.';
            END

            UPDATE #DbResults SET DbScore = @DbScore, Finding = @DbFinding WHERE DbName = @DbName;
        END TRY
        BEGIN CATCH
            UPDATE #DbResults SET DbScore = 0, Finding = 'Database evaluation failed: ' + ERROR_MESSAGE() WHERE DbName = @DbName;
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ') WITHIN GROUP (ORDER BY DbName)
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ') WITHIN GROUP (ORDER BY DbName)
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