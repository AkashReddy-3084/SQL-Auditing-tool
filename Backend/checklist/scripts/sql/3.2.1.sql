-- Checklist: Business/transformation logic encapsulated in stored procedures/functions (not ad-hoc scripts)
-- Scope: SERVER
-- Scoring: 3 = No ad-hoc job steps found; 2 = < 5% of job steps are ad-hoc; 1 = 5-25% ad-hoc; 0 = > 25% ad-hoc

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No evidence found';

DECLARE @TotalSteps INT = 0;
DECLARE @AdHocSteps INT = 0;
DECLARE @AdHocList NVARCHAR(MAX) = '';

-- Identify SQL Agent job steps that execute T-SQL but do not call a procedure/function
-- We look for steps where the command does not start with EXEC or contains no procedure call patterns
-- This is a proxy for "ad-hoc" logic within the Agent.
SELECT 
    @TotalSteps = COUNT(*),
    @AdHocSteps = SUM(CASE WHEN (command NOT LIKE '%EXEC%' AND command NOT LIKE '%EXECUTE%') THEN 1 ELSE 0 END),
    @AdHocList = ISNULL(STRING_AGG(CASE WHEN (command NOT LIKE '%EXEC%' AND command NOT LIKE '%EXECUTE%') THEN QUOTENAME(j.name) + '.Step' + CAST(s.step_id AS VARCHAR(5)) ELSE NULL END, ', '), '')
FROM msdb.dbo.sysjobsteps s
JOIN msdb.dbo.sysjobs j ON s.job_id = j.job_id
WHERE s.subsystem = 'TSQL';

IF @TotalSteps = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No T-SQL Agent jobs found; by default, no ad-hoc scripts are present.';
END
ELSE
BEGIN
    DECLARE @Ratio FLOAT = CAST(@AdHocSteps AS FLOAT) / NULLIF(@TotalSteps, 0);
    
    IF @AdHocSteps = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No ad-hoc T-SQL job steps found. All logic appears encapsulated.';
    END
    ELSE IF @Ratio < 0.05
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Minor ad-hoc logic found (' + CAST(CAST(@Ratio*100 AS DECIMAL(5,2)) AS VARCHAR(10)) + '%): ' + @AdHocList;
    END
    ELSE IF @Ratio < 0.25
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Significant ad-hoc logic found (' + CAST(CAST(@Ratio*100 AS DECIMAL(5,2)) AS VARCHAR(10)) + '%): ' + @AdHocList;
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'High volume of ad-hoc logic found (' + CAST(CAST(@Ratio*100 AS DECIMAL(5,2)) AS VARCHAR(10)) + '%): ' + @AdHocList;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;