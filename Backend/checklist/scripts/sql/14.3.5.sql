-- Checklist: Lock escalation understood and mitigated where problematic
-- Scope: DATABASE
-- Scoring: 3 = at least 75% of user tables use non-TABLE escalation and no escalations are recorded; 2 = at least 50% are tuned, or at least 75% are tuned with escalations; 1 = more than 0% but below 50% are tuned; 0 = no tables are tuned, escalations are present with no tuned tables, or evidence is unavailable
-- NOTE: Automated evidence identifies configured mitigation and observed escalations; whether escalation is problematic requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Lock-escalation evidence unavailable';
DECLARE @TablesTotal INT = 0;
DECLARE @TunedTables INT = 0;
DECLARE @Escalations BIGINT = 0;
DECLARE @TunedPercent DECIMAL(6, 2) = 0.00;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT
        @TablesTotal = COUNT(*),
        @TunedTables = ISNULL(SUM(CASE WHEN t.lock_escalation_desc <> N'TABLE' THEN 1 ELSE 0 END), 0)
    FROM sys.tables AS t
    WHERE t.is_ms_shipped = 0;

    SELECT @Escalations = ISNULL(SUM(index_lock_promotion_count), 0)
    FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL);
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @TunedPercent = CASE
    WHEN @TablesTotal = 0 THEN 0.00
    ELSE CONVERT(DECIMAL(6, 2), 100.0 * @TunedTables / NULLIF(@TablesTotal, 0))
END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @TablesTotal = 0 THEN 2
    WHEN @TunedPercent >= 75.00 AND @Escalations = 0 THEN 3
    WHEN @TunedPercent >= 75.00 OR @TunedPercent >= 50.00 THEN 2
    WHEN @TunedPercent > 0.00 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'user tables = ', @TablesTotal,
    N'; tuned tables = ', @TunedTables,
    N'; tuned percentage = ', @TunedPercent, N'%',
    N'; index lock promotions = ', @Escalations,
    CASE WHEN @ReadError = 1 THEN N'; one or more lock sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
