SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @ProductMajor INT = TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT);
DECLARE @ProductVersion NVARCHAR(128) = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128));

IF OBJECT_ID('tempdb..#QueryStore') IS NOT NULL
    DROP TABLE #QueryStore;

CREATE TABLE #QueryStore
(
    DatabaseName     SYSNAME        NOT NULL,
    ActualState      NVARCHAR(60)   NULL,
    DesiredState     NVARCHAR(60)   NULL,
    ForcedPlanCount  INT            NULL,
    FailedForceCount INT            NULL,
    ErrorMessage     NVARCHAR(400)  NULL
);

IF (@ProductMajor IS NULL OR @ProductMajor >= 13)
BEGIN
    IF @EngineEdition = 5
    BEGIN
        -- Azure SQL Database: cross-database queries are not possible, inspect the current database only.
        BEGIN TRY
            INSERT INTO #QueryStore (DatabaseName, ActualState, DesiredState, ForcedPlanCount, FailedForceCount)
            SELECT
                DB_NAME(),
                (SELECT TOP (1) o.actual_state_desc FROM sys.database_query_store_options AS o),
                (SELECT TOP (1) o.desired_state_desc FROM sys.database_query_store_options AS o),
                (SELECT COUNT(*) FROM sys.query_store_plan AS p WHERE p.is_forced_plan = 1),
                (SELECT COUNT(*) FROM sys.query_store_plan AS p WHERE p.is_forced_plan = 1 AND p.last_force_failure_reason <> 0);
        END TRY
        BEGIN CATCH
            INSERT INTO #QueryStore (DatabaseName, ErrorMessage)
            VALUES (DB_NAME(), LEFT(ERROR_MESSAGE(), 400));
        END CATCH
    END
    ELSE
    BEGIN
        DECLARE @DbName SYSNAME;
        DECLARE @Sql NVARCHAR(MAX);

        DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT d.name
            FROM sys.databases AS d
            WHERE d.database_id > 4
              AND d.state = 0
              AND d.source_database_id IS NULL
              AND d.is_in_standby = 0
              AND HAS_DBACCESS(d.name) = 1
            ORDER BY d.name;

        OPEN db_cursor;
        FETCH NEXT FROM db_cursor INTO @DbName;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'SELECT @db,
       (SELECT TOP (1) o.actual_state_desc FROM ' + QUOTENAME(@DbName) + N'.sys.database_query_store_options AS o),
       (SELECT TOP (1) o.desired_state_desc FROM ' + QUOTENAME(@DbName) + N'.sys.database_query_store_options AS o),
       (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.query_store_plan AS p WHERE p.is_forced_plan = 1),
       (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.query_store_plan AS p WHERE p.is_forced_plan = 1 AND p.last_force_failure_reason <> 0);';

                INSERT INTO #QueryStore (DatabaseName, ActualState, DesiredState, ForcedPlanCount, FailedForceCount)
                EXEC sp_executesql @Sql, N'@db SYSNAME', @db = @DbName;
            END TRY
            BEGIN CATCH
                INSERT INTO #QueryStore (DatabaseName, ErrorMessage)
                VALUES (@DbName, LEFT(ERROR_MESSAGE(), 400));
            END CATCH

            FETCH NEXT FROM db_cursor INTO @DbName;
        END

        CLOSE db_cursor;
        DEALLOCATE db_cursor;
    END
END

DECLARE @TotalDbs        INT = (SELECT COUNT(*) FROM #QueryStore);
DECLARE @ErrorDbs        INT = (SELECT COUNT(*) FROM #QueryStore WHERE ErrorMessage IS NOT NULL);
DECLARE @EnabledDbs      INT = (SELECT COUNT(*) FROM #QueryStore WHERE ActualState IN (N'READ_WRITE', N'READ_ONLY'));
DECLARE @ReadWriteDbs    INT = (SELECT COUNT(*) FROM #QueryStore WHERE ActualState = N'READ_WRITE');
DECLARE @DbsWithForced   INT = (SELECT COUNT(*) FROM #QueryStore WHERE ISNULL(ForcedPlanCount, 0) > 0);
DECLARE @TotalForced     INT = (SELECT ISNULL(SUM(ISNULL(ForcedPlanCount, 0)), 0) FROM #QueryStore);
DECLARE @TotalFailed     INT = (SELECT ISNULL(SUM(ISNULL(FailedForceCount, 0)), 0) FROM #QueryStore);

DECLARE @NotEnabledList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + q.DatabaseName + N' (' + ISNULL(q.ActualState, ISNULL(N'error: ' + q.ErrorMessage, N'unknown')) + N')'
           FROM #QueryStore AS q
           WHERE q.ErrorMessage IS NOT NULL
              OR ISNULL(q.ActualState, N'OFF') NOT IN (N'READ_WRITE', N'READ_ONLY')
           ORDER BY q.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @ForcedList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + q.DatabaseName + N'=' + CAST(q.ForcedPlanCount AS NVARCHAR(20))
           FROM #QueryStore AS q
           WHERE ISNULL(q.ForcedPlanCount, 0) > 0
           ORDER BY q.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @DatabaseQueried NVARCHAR(MAX) =
    STUFF((SELECT N', ' + q.DatabaseName
           FROM #QueryStore AS q
           ORDER BY q.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Result  NVARCHAR(20);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(4000);

IF @TotalDbs = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END
ELSE IF (@ProductMajor IS NOT NULL AND @ProductMajor < 13)
BEGIN
    SET @Score = 0;
    SET @Finding = N'SQL Server version ' + @ProductVersion + N' predates SQL Server 2016 and has no Query Store feature, so plans cannot be forced to stabilise regressions.';
END
ELSE IF @EnabledDbs = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'Query Store is not enabled on any of the ' + CAST(@TotalDbs AS NVARCHAR(10)) + N' user database(s) examined, so no plan regression history is captured and no plan can be forced. Databases without Query Store: ' + ISNULL(@NotEnabledList, N'none listed') + N'.';
END
ELSE IF @EnabledDbs < @TotalDbs AND @DbsWithForced = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Query Store is enabled on only ' + CAST(@EnabledDbs AS NVARCHAR(10)) + N' of ' + CAST(@TotalDbs AS NVARCHAR(10)) + N' user database(s) (' + CAST(@ReadWriteDbs AS NVARCHAR(10)) + N' in READ_WRITE) and no forced plans exist anywhere. Databases without Query Store: ' + ISNULL(@NotEnabledList, N'none listed') + N'.';
END
ELSE IF @DbsWithForced = 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Query Store is enabled on all ' + CAST(@TotalDbs AS NVARCHAR(10)) + N' user database(s) (' + CAST(@ReadWriteDbs AS NVARCHAR(10)) + N' in READ_WRITE), but no plan is currently forced, so the practice of forcing stable plans on regression is not evidenced by server state.';
END
ELSE IF @EnabledDbs < @TotalDbs
BEGIN
    SET @Score = 2;
    SET @Finding = N'Plan forcing is in use (' + CAST(@TotalForced AS NVARCHAR(10)) + N' forced plan(s) across ' + CAST(@DbsWithForced AS NVARCHAR(10)) + N' database(s): ' + ISNULL(@ForcedList, N'') + N') but Query Store coverage is incomplete - enabled on only ' + CAST(@EnabledDbs AS NVARCHAR(10)) + N' of ' + CAST(@TotalDbs AS NVARCHAR(10)) + N' user database(s). Databases without Query Store: ' + ISNULL(@NotEnabledList, N'none listed') + N'.';
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = N'Query Store is enabled on all ' + CAST(@TotalDbs AS NVARCHAR(10)) + N' user database(s) (' + CAST(@ReadWriteDbs AS NVARCHAR(10)) + N' in READ_WRITE) and ' + CAST(@TotalForced AS NVARCHAR(10)) + N' plan(s) are forced across ' + CAST(@DbsWithForced AS NVARCHAR(10)) + N' database(s): ' + ISNULL(@ForcedList, N'') + N'.'
                 + CASE WHEN @TotalFailed > 0 THEN N' Note: ' + CAST(@TotalFailed AS NVARCHAR(10)) + N' forced plan(s) report a last force failure and should be reviewed.' ELSE N'' END;
END

IF @TotalDbs > 0 AND @ErrorDbs > 0
    SET @Finding = LEFT(@Finding + N' ' + CAST(@ErrorDbs AS NVARCHAR(10)) + N' database(s) could not be queried for Query Store metadata.', 4000);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#QueryStore') IS NOT NULL
    DROP TABLE #QueryStore;