-- Checklist: Query Store used to force stable plans where regressions occur
-- Scope: DATABASE
-- Scoring: 0=Query Store disabled, 1=Read-Only mode, 2=Enabled but no forced plans, 3=Enabled with forced plans configured

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
    SET @DbName = DB_NAME();
    BEGIN TRY
        SET @Sql = N'
            DECLARE @ActualState INT;
            DECLARE @ForcedPlanCount INT;
            DECLARE @DbScore INT;
            DECLARE @Finding NVARCHAR(MAX);

            SELECT @ActualState = actual_state FROM sys.database_query_store_options;
            SELECT @ForcedPlanCount = COUNT(*) FROM sys.query_store_plan WHERE is_forced_plan = 1;

            IF @ActualState = 0
            BEGIN
                SET @DbScore = 0;
                SET @Finding = ''Query Store is disabled.'';
            END
            ELSE IF @ActualState = 1
            BEGIN
                SET @DbScore = 1;
                SET @Finding = ''Query Store is in Read-Only mode.'';
            END
            ELSE IF @ActualState = 2 AND @ForcedPlanCount = 0
            BEGIN
                SET @DbScore = 2;
                SET @Finding = ''Query Store is enabled, but no forced plans are configured.'';
            END
            ELSE IF @ActualState = 2 AND @ForcedPlanCount > 0
            BEGIN
                SET @DbScore = 3;
                SET @Finding = ''Query Store is enabled with '' + CAST(@ForcedPlanCount AS NVARCHAR) + '' forced plan(s) configured.'';
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @Finding = ''Query Store state unknown: '' + CAST(@ActualState AS NVARCHAR);
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@pDbName, @DbScore, @Finding);
        ';
        EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE
BEGIN
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
                DECLARE @ActualState INT;
                DECLARE @ForcedPlanCount INT;
                DECLARE @DbScore INT;
                DECLARE @Finding NVARCHAR(MAX);

                SELECT @ActualState = actual_state FROM sys.database_query_store_options;
                SELECT @ForcedPlanCount = COUNT(*) FROM sys.query_store_plan WHERE is_forced_plan = 1;

                IF @ActualState = 0
                BEGIN
                    SET @DbScore = 0;
                    SET @Finding = ''Query Store is disabled.'';
                END
                ELSE IF @ActualState = 1
                BEGIN
                    SET @DbScore = 1;
                    SET @Finding = ''Query Store is in Read-Only mode.'';
                END
                ELSE IF @ActualState = 2 AND @ForcedPlanCount = 0
                BEGIN
                    SET @DbScore = 2;
                    SET @Finding = ''Query Store is enabled, but no forced plans are configured.'';
                END
                ELSE IF @ActualState = 2 AND @ForcedPlanCount > 0
                BEGIN
                    SET @DbScore = 3;
                    SET @Finding = ''Query Store is enabled with '' + CAST(@ForcedPlanCount AS NVARCHAR) + '' forced plan(s) configured.'';
                END
                ELSE
                BEGIN
                    SET @DbScore = 0;
                    SET @Finding = ''Query Store state unknown: '' + CAST(@ActualState AS NVARCHAR);
                END

                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (@pDbName, @DbScore, @Finding);
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