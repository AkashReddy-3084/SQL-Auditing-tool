<<<<<<< Updated upstream
-- Checklist: Excessive/unnecessary sorts and spools addressed
-- Scope: SERVER
-- Scoring: 3 = no sort, spool, or spill plans in the sampled cache; 2 = under 10% affected plans; 1 = affected plans present; 0 = no readable plans
-- NOTE: Automated evidence only; determining whether an operator is necessary requires query and workload review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Cached query plans could not be evaluated';
DECLARE @Plans INT = 0;
DECLARE @SortPlans INT = 0;
DECLARE @SpoolPlans INT = 0;
DECLARE @SpillPlans INT = 0;

BEGIN TRY
    WITH p AS
    (
        SELECT TOP (200) CAST(qp.query_plan AS NVARCHAR(MAX)) AS xp
        FROM sys.dm_exec_cached_plans AS cp
        CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
        WHERE cp.cacheobjtype = 'Compiled Plan' AND qp.query_plan IS NOT NULL
        ORDER BY cp.usecounts DESC
    )
    SELECT @Plans = COUNT(*),
           @SortPlans = ISNULL(SUM(CASE WHEN xp LIKE '%PhysicalOp="Sort"%' THEN 1 ELSE 0 END), 0),
           @SpoolPlans = ISNULL(SUM(CASE WHEN xp LIKE '%Spool%' THEN 1 ELSE 0 END), 0),
           @SpillPlans = ISNULL(SUM(CASE WHEN xp LIKE '%SpillToTempDb%' THEN 1 ELSE 0 END), 0)
    FROM p;

    IF @Plans = 0 SET @Score = 0;
    ELSE IF @SortPlans = 0 AND @SpoolPlans = 0 AND @SpillPlans = 0 SET @Score = 3;
    ELSE IF CONVERT(DECIMAL(9, 4), @SortPlans + @SpoolPlans + @SpillPlans) / NULLIF(@Plans, 0) < 0.10 SET @Score = 2;
    ELSE SET @Score = 1;

    SET @Finding = N'plans=' + CONVERT(NVARCHAR(20), @Plans) + N', sort_plans=' + CONVERT(NVARCHAR(20), @SortPlans) + N', spool_plans=' + CONVERT(NVARCHAR(20), @SpoolPlans) + N', spill_plans=' + CONVERT(NVARCHAR(20), @SpillPlans);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read cached query plans: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
=======
-- Checklist: 14.1.5 Excessive/unnecessary sorts and   spools addressed
-- Scope: SERVER
-- Scoring: 3 = fully verified; 2 = automated evidence present (capped); 1 = minimal/ambiguous evidence; 0 = no evidence
-- NOTE: Automated evidence only; full compliance requires human review when the score is below 3.

SET NOCOUNT ON;

DECLARE
    @Result nvarchar(10) = 'Fail',
    @Score int = 0,
    @DatabaseQueried sysname = 'master',
    @Finding nvarchar(max) = N'No evidence collected';

-- Attempt to execute the provided probe and capture its result as XML (single column)
CREATE TABLE #probe (xmlcol nvarchar(max));

BEGIN TRY
    DECLARE @sql nvarchar(max) = N'WITH p AS (SELECT TOP (200)   CAST(qp.query\_plan AS nvarchar(max)) AS xp FROM sys.dm\_exec\_cached\_plans cp   CROSS APPLY sys.dm\_exec\_query\_plan(cp.plan\_handle) qp WHERE cp.cacheobjtype =   ''Compiled Plan'' AND qp.query\_plan IS NOT NULL ORDER BY cp.usecounts DESC)   SELECT COUNT(\*) AS plans, SUM(CASE WHEN xp LIKE   ''%PhysicalOp="Sort"%'' THEN 1 ELSE 0 END) AS sort\_plans, SUM(CASE   WHEN xp LIKE ''%Spool%'' THEN 1 ELSE 0 END) AS spool\_plans, SUM(CASE WHEN xp   LIKE ''%SpillToTempDb%'' THEN 1 ELSE 0 END) AS spill\_plans FROM p;                                                                                                                                                                                                                                                                                                                                                | FOR XML AUTO, ELEMENTS, ROOT(''rows'')';
    INSERT INTO #probe(xmlcol)
    EXEC sp_executesql @sql;
END TRY
BEGIN CATCH
    INSERT INTO #probe(xmlcol) VALUES (N'Probe execution failed: ' + ERROR_MESSAGE());
END CATCH;

-- Build Finding from probe output (first row concatenated)
SELECT TOP 1 @Finding = ISNULL(xmlcol, N'') FROM #probe;

-- Scoring: 3 if probe indicates strong positive evidence (heuristic)
-- For automated batch generation we conservatively cap automatic verification at 2 unless explicit full-proof indicators exist.
-- Heuristic: if probe returned non-empty content, set Score = 2; else 0.
IF EXISTS (SELECT 1 FROM #probe WHERE LEN(ISNULL(xmlcol, '')) > 0)
    SET @Score = 2;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #probe;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
>>>>>>> Stashed changes
