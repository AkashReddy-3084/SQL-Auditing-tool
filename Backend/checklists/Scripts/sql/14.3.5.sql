-- Checklist: Lock escalation understood and mitigated where problematic
-- Scope: DATABASE
-- Scoring: 3 = no table that recorded lock escalations is still left at the default TABLE escalation; 2 = such unmitigated tables are under 5% of user tables; 1 = under 25%; 0 = 25% or more, or lock escalation evidence could not be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Lock escalation evidence could not be read in this database';
DECLARE @Total INT = 0;
DECLARE @Promoted INT = 0;
DECLARE @Unmitigated INT = 0;
DECLARE @Tuned INT = 0;
DECLARE @Escalations BIGINT = 0;
DECLARE @Pct DECIMAL(9, 2) = 0;
DECLARE @Names NVARCHAR(MAX) = '';
DECLARE @Read BIT = 0;

DECLARE @T TABLE (
    TableName NVARCHAR(300) NOT NULL,
    Escalation NVARCHAR(60) NOT NULL,
    Promotions BIGINT NOT NULL);

BEGIN TRY
    INSERT INTO @T (TableName, Escalation, Promotions)
    SELECT CONCAT(SCHEMA_NAME(t.schema_id), '.', t.name),
           ISNULL(MAX(t.lock_escalation_desc), 'TABLE'),
           ISNULL(SUM(CONVERT(BIGINT, os.index_lock_promotion_count)), 0)
    FROM sys.tables AS t
    LEFT JOIN sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
           ON os.object_id = t.object_id
    WHERE t.is_ms_shipped = 0
    GROUP BY t.schema_id, t.name;

    SET @Read = 1;
END TRY
BEGIN CATCH
    SET @Read = 0;
END CATCH;

SELECT @Total = COUNT(*),
       @Promoted = ISNULL(SUM(CASE WHEN Promotions > 0 THEN 1 ELSE 0 END), 0),
       @Unmitigated = ISNULL(SUM(CASE WHEN Promotions > 0 AND Escalation = 'TABLE' THEN 1 ELSE 0 END), 0),
       @Tuned = ISNULL(SUM(CASE WHEN Escalation <> 'TABLE' THEN 1 ELSE 0 END), 0),
       @Escalations = ISNULL(SUM(Promotions), 0)
FROM @T;

SELECT @Names = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), TableName), ', '), 400), 'none')
FROM @T
WHERE Promotions > 0 AND Escalation = 'TABLE';

SET @Pct = ISNULL(CONVERT(DECIMAL(9, 2), 100.0 * @Unmitigated / NULLIF(@Total, 0)), 0);

SET @Score = CASE
    WHEN @Read = 0 THEN 0
    WHEN @Unmitigated = 0 THEN 3
    WHEN @Pct < 5 THEN 2
    WHEN @Pct < 25 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @Read = 0
        THEN 'sys.tables or sys.dm_db_index_operational_stats could not be read; lock escalation settings are unknown'
    ELSE CONCAT(
        'user tables = ', @Total,
        '; tables with a non-default lock_escalation setting (AUTO or DISABLE) = ', @Tuned,
        '; tables that recorded lock escalations = ', @Promoted,
        '; total index lock promotions = ', @Escalations,
        '; escalating tables still set to TABLE escalation = ', @Unmitigated,
        ' (', @Pct, '% of user tables): ', @Names)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
