-- Checklist: Excessive/unnecessary sorts and spools addressed
-- Scope: SERVER
-- Scoring: 3 = no sampled plan contains a Sort or Spool operator; 2 = under 15 percent affected; 1 = under 40 percent affected; 0 = 40 percent or more affected, or the plan cache is empty/unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Cached execution plans could not be read';
DECLARE @Plans INT = 0;
DECLARE @Sorts INT = 0;
DECLARE @Spools INT = 0;
DECLARE @Affected INT = 0;
DECLARE @HotExecs BIGINT = 0;
DECLARE @Pct DECIMAL(9,4) = 0;
DECLARE @Readable BIT = 0;

BEGIN TRY
    ;WITH p AS
    (
        SELECT TOP (200)
               CONVERT(NVARCHAR(MAX), qp.query_plan) AS Xp,
               CONVERT(BIGINT, cp.usecounts) AS Uses
        FROM sys.dm_exec_cached_plans AS cp
        CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
        WHERE cp.cacheobjtype = 'Compiled Plan'
          AND qp.query_plan IS NOT NULL
        ORDER BY cp.usecounts DESC
    )
    SELECT @Plans = COUNT(*),
           @Sorts = ISNULL(SUM(CASE WHEN Xp LIKE '%PhysicalOp="Sort"%' THEN 1 ELSE 0 END), 0),
           @Spools = ISNULL(SUM(CASE WHEN Xp LIKE '%Spool%' THEN 1 ELSE 0 END), 0),
           @Affected = ISNULL(SUM(CASE WHEN Xp LIKE '%PhysicalOp="Sort"%' OR Xp LIKE '%Spool%' THEN 1 ELSE 0 END), 0),
           @HotExecs = ISNULL(SUM(CASE WHEN Xp LIKE '%PhysicalOp="Sort"%' OR Xp LIKE '%Spool%' THEN Uses ELSE 0 END), 0)
    FROM p;

    SET @Readable = 1;
END TRY
BEGIN CATCH
    SET @Readable = 0;
END CATCH;

SET @Pct = ISNULL(CONVERT(DECIMAL(9,4), @Affected) / NULLIF(@Plans, 0), 0);

SET @Score = CASE
                WHEN @Readable = 0 OR @Plans = 0 THEN 0
                WHEN @Affected = 0 THEN 3
                WHEN @Pct < 0.15 THEN 2
                WHEN @Pct < 0.40 THEN 1
                ELSE 0
             END;

SET @Finding = CASE
    WHEN @Readable = 0
        THEN 'The plan cache DMVs are not readable by the audit login, so sort and spool usage could not be measured'
    WHEN @Plans = 0
        THEN 'The plan cache returned no compiled plans, so sort and spool usage could not be measured'
    WHEN @Affected = 0
        THEN CONCAT('Sampled the ', @Plans, ' most-executed cached plans: none contain a Sort or Spool operator')
    ELSE CONCAT('Sampled the ', @Plans, ' most-executed cached plans: ', @Affected, ' (',
                CONVERT(DECIMAL(9,1), @Pct * 100), ' percent) contain a Sort or Spool operator (',
                @Sorts, ' with Sort, ', @Spools, ' with Spool) accounting for ', @HotExecs, ' cached executions')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;

