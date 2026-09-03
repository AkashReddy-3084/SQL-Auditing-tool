SET NOCOUNT ON;

DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @DatabaseQueried nvarchar(128) = N'None';
DECLARE @Finding nvarchar(2000);
DECLARE @ActualState nvarchar(60);
DECLARE @RecentExecutions bigint = 0;
DECLARE @BaselineExecutions bigint = 0;
DECLARE @RegressedQueries int = 0;
DECLARE @RegressedQueriesWithForcedPlan int = 0;

IF DB_ID() <= 4
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SET @DatabaseQueried = DB_NAME();

    BEGIN TRY
        SELECT @ActualState = actual_state_desc
        FROM sys.database_query_store_options;

        IF @ActualState IS NULL OR @ActualState IN (N'OFF', N'ERROR')
        BEGIN
            SET @Score = 0;
            SET @Finding = N'Query Store is not operational; actual state is ' + COALESCE(@ActualState, N'unavailable') + N'.';
        END
        ELSE
        BEGIN
            SELECT
                @RecentExecutions = COALESCE(SUM(CASE
                    WHEN rsi.start_time >= DATEADD(DAY, -1, SYSUTCDATETIME())
                        THEN CONVERT(bigint, rs.count_executions)
                    ELSE CONVERT(bigint, 0)
                END), 0),
                @BaselineExecutions = COALESCE(SUM(CASE
                    WHEN rsi.start_time >= DATEADD(DAY, -8, SYSUTCDATETIME())
                     AND rsi.end_time <= DATEADD(DAY, -1, SYSUTCDATETIME())
                        THEN CONVERT(bigint, rs.count_executions)
                    ELSE CONVERT(bigint, 0)
                END), 0)
            FROM sys.query_store_runtime_stats AS rs
            INNER JOIN sys.query_store_runtime_stats_interval AS rsi
                ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id;

            IF @RecentExecutions = 0 OR @BaselineExecutions = 0
            BEGIN
                SET @Score = 2;
                SET @Finding = CONCAT(
                    N'Query Store is ', @ActualState,
                    N', but history is insufficient for regression comparison. Recent executions: ',
                    @RecentExecutions, N'; baseline executions: ', @BaselineExecutions, N'.'
                );
            END
            ELSE
            BEGIN
                ;WITH QueryPerformance AS
                (
                    SELECT
                        q.query_id,
                        SUM(CASE
                            WHEN rsi.start_time >= DATEADD(DAY, -1, SYSUTCDATETIME())
                                THEN CONVERT(bigint, rs.count_executions)
                            ELSE CONVERT(bigint, 0)
                        END) AS recent_executions,
                        SUM(CASE
                            WHEN rsi.start_time >= DATEADD(DAY, -8, SYSUTCDATETIME())
                             AND rsi.end_time <= DATEADD(DAY, -1, SYSUTCDATETIME())
                                THEN CONVERT(bigint, rs.count_executions)
                            ELSE CONVERT(bigint, 0)
                        END) AS baseline_executions,
                        SUM(CASE
                            WHEN rsi.start_time >= DATEADD(DAY, -1, SYSUTCDATETIME())
                                THEN CONVERT(decimal(38, 4), rs.avg_duration) * rs.count_executions
                            ELSE CONVERT(decimal(38, 4), 0)
                        END)
                        / NULLIF(SUM(CASE
                            WHEN rsi.start_time >= DATEADD(DAY, -1, SYSUTCDATETIME())
                                THEN CONVERT(decimal(38, 4), rs.count_executions)
                            ELSE CONVERT(decimal(38, 4), 0)
                        END), 0) AS recent_avg_duration,
                        SUM(CASE
                            WHEN rsi.start_time >= DATEADD(DAY, -8, SYSUTCDATETIME())
                             AND rsi.end_time <= DATEADD(DAY, -1, SYSUTCDATETIME())
                                THEN CONVERT(decimal(38, 4), rs.avg_duration) * rs.count_executions
                            ELSE CONVERT(decimal(38, 4), 0)
                        END)
                        / NULLIF(SUM(CASE
                            WHEN rsi.start_time >= DATEADD(DAY, -8, SYSUTCDATETIME())
                             AND rsi.end_time <= DATEADD(DAY, -1, SYSUTCDATETIME())
                                THEN CONVERT(decimal(38, 4), rs.count_executions)
                            ELSE CONVERT(decimal(38, 4), 0)
                        END), 0) AS baseline_avg_duration
                    FROM sys.query_store_query AS q
                    INNER JOIN sys.query_store_plan AS p
                        ON p.query_id = q.query_id
                    INNER JOIN sys.query_store_runtime_stats AS rs
                        ON rs.plan_id = p.plan_id
                    INNER JOIN sys.query_store_runtime_stats_interval AS rsi
                        ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
                    WHERE rsi.start_time >= DATEADD(DAY, -8, SYSUTCDATETIME())
                    GROUP BY q.query_id
                ),
                RegressedQueries AS
                (
                    SELECT query_id
                    FROM QueryPerformance
                    WHERE recent_executions >= 5
                      AND baseline_executions >= 5
                      AND recent_avg_duration > baseline_avg_duration * CONVERT(decimal(5, 2), 1.50)
                ),
                ForcedQueries AS
                (
                    SELECT DISTINCT query_id
                    FROM sys.query_store_plan
                    WHERE is_forced_plan = 1
                )
                SELECT
                    @RegressedQueries = COUNT(*),
                    @RegressedQueriesWithForcedPlan = COALESCE(SUM(CASE WHEN fq.query_id IS NOT NULL THEN 1 ELSE 0 END), 0)
                FROM RegressedQueries AS rq
                LEFT JOIN ForcedQueries AS fq
                    ON fq.query_id = rq.query_id;

                IF @RegressedQueries = 0
                BEGIN
                    SET @Score = 3;
                    SET @Finding = CONCAT(
                        N'Query Store is ', @ActualState,
                        N'; no qualifying duration regressions were detected in the recent one-day window versus the preceding seven-day baseline.'
                    );
                END
                ELSE IF @RegressedQueriesWithForcedPlan = @RegressedQueries
                BEGIN
                    SET @Score = 3;
                    SET @Finding = CONCAT(
                        N'All ', @RegressedQueries,
                        N' qualifying regressed queries have a forced plan.'
                    );
                END
                ELSE IF @RegressedQueriesWithForcedPlan > 0
                BEGIN
                    SET @Score = 1;
                    SET @Finding = CONCAT(
                        @RegressedQueriesWithForcedPlan, N' of ', @RegressedQueries,
                        N' qualifying regressed queries have a forced plan.'
                    );
                END
                ELSE
                BEGIN
                    SET @Score = 0;
                    SET @Finding = CONCAT(
                        N'None of the ', @RegressedQueries,
                        N' qualifying regressed queries have a forced plan.'
                    );
                END;
            END;
        END;
    END TRY
    BEGIN CATCH
        SET @Score = 0;
        SET @Finding = CONCAT(N'Unable to inspect Query Store evidence: ', ERROR_MESSAGE());
    END CATCH;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;