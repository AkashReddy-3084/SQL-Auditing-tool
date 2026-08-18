-- Checklist: Maintenance procedures documented (index/stats/integrity)
-- Scope: SERVER
-- Scoring: 0: No maintenance jobs/procedures found. 1: Maintenance jobs/procedures exist but lack inline documentation/comments. 2: Maintenance jobs/procedures exist with inline comments/documentation (proxy evidence). 3: Not achievable automatically; requires human review of documentation quality.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

DECLARE @MaintJobs TABLE (
    JobName NVARCHAR(128),
    HasComments BIT,
    StepCommand NVARCHAR(MAX)
);

-- Check SQL Agent jobs if msdb is available (SQL Server / Azure SQL MI)
IF @EngineEdition <> 5 AND OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    INSERT INTO @MaintJobs
    SELECT 
        j.name AS JobName,
        CASE WHEN ISNULL(js.command, '') LIKE '%--%' OR ISNULL(js.command, '') LIKE '%/*%' THEN 1 ELSE 0 END AS HasComments,
        LEFT(ISNULL(js.command, ''), 4000) AS StepCommand
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE j.enabled = 1
      AND (
        j.name LIKE '%index%' OR j.name LIKE '%stats%' OR j.name LIKE '%integrity%' OR j.name LIKE '%maintenance%'
        OR ISNULL(js.command, '') LIKE '%sp_index%' OR ISNULL(js.command, '') LIKE '%sp_updatestats%' OR ISNULL(js.command, '') LIKE '%DBCC CHECKDB%' OR ISNULL(js.command, '') LIKE '%ALTER INDEX%' OR ISNULL(js.command, '') LIKE '%UPDATE STATISTICS%'
      );
END
ELSE
BEGIN
    -- Fallback for Azure SQL Database: check local stored procedures
    INSERT INTO @MaintJobs
    SELECT 
        p.name AS JobName,
        CASE WHEN ISNULL(m.definition, '') LIKE '%--%' OR ISNULL(m.definition, '') LIKE '%/*%' THEN 1 ELSE 0 END AS HasComments,
        LEFT(ISNULL(m.definition, ''), 4000) AS StepCommand
    FROM sys.procedures p
    INNER JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE p.is_ms_shipped = 0
      AND (
        p.name LIKE '%index%' OR p.name LIKE '%stats%' OR p.name LIKE '%integrity%' OR p.name LIKE '%maintenance%'
        OR ISNULL(m.definition, '') LIKE '%sp_index%' OR ISNULL(m.definition, '') LIKE '%sp_updatestats%' OR ISNULL(m.definition, '') LIKE '%DBCC CHECKDB%' OR ISNULL(m.definition, '') LIKE '%ALTER INDEX%' OR ISNULL(m.definition, '') LIKE '%UPDATE STATISTICS%'
      );
END

DECLARE @JobCount INT = (SELECT COUNT(*) FROM @MaintJobs);
DECLARE @CommentCount INT = (SELECT COUNT(*) FROM @MaintJobs WHERE HasComments = 1);

IF @JobCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No maintenance jobs or procedures found for index, statistics, or integrity checks.';
END
ELSE IF @CommentCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Maintenance jobs/procedures found (' + CAST(@JobCount AS NVARCHAR) + ') but lack inline documentation/comments. Example: ' + (SELECT TOP 1 JobName FROM @MaintJobs);
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = 'Maintenance jobs/procedures found (' + CAST(@JobCount AS NVARCHAR) + ') with inline comments. Documented: ' + CAST(@CommentCount AS NVARCHAR) + '. -- NOTE: This script provides automated evidence. Full compliance requires human review.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;