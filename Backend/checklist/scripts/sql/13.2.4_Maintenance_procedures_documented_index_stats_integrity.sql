-- Checklist: Maintenance procedures documented (index/stats/integrity)
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=One maintenance type found, 2=Two or three types found (capped at 2 due to proxy evidence)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @IndexCount INT = 0;
DECLARE @StatsCount INT = 0;
DECLARE @IntegrityCount INT = 0;

-- Check SQL Agent Jobs (if available)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT @IndexCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE js.command LIKE '%ALTER INDEX%' OR js.command LIKE '%sp_index%' OR js.command LIKE '%rebuild%' OR js.command LIKE '%reorganize%';

    SELECT @StatsCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE js.command LIKE '%UPDATE STATISTICS%' OR js.command LIKE '%sp_updatestats%' OR js.command LIKE '%stats%';

    SELECT @IntegrityCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE js.command LIKE '%DBCC CHECKDB%' OR js.command LIKE '%DBCC CHECKCATALOG%';
END

-- Fallback: Check stored procedures in master if jobs not found
IF @IndexCount = 0
BEGIN
    SELECT @IndexCount = COUNT(DISTINCT p.object_id)
    FROM master.sys.procedures p
    INNER JOIN master.sys.sql_modules m ON p.object_id = m.object_id
    WHERE m.definition LIKE '%ALTER INDEX%' OR m.definition LIKE '%sp_index%';
END
IF @StatsCount = 0
BEGIN
    SELECT @StatsCount = COUNT(DISTINCT p.object_id)
    FROM master.sys.procedures p
    INNER JOIN master.sys.sql_modules m ON p.object_id = m.object_id
    WHERE m.definition LIKE '%UPDATE STATISTICS%' OR m.definition LIKE '%sp_updatestats%';
END
IF @IntegrityCount = 0
BEGIN
    SELECT @IntegrityCount = COUNT(DISTINCT p.object_id)
    FROM master.sys.procedures p
    INNER JOIN master.sys.sql_modules m ON p.object_id = m.object_id
    WHERE m.definition LIKE '%DBCC CHECKDB%';
END

DECLARE @TypesFound INT = 0;
IF @IndexCount > 0 SET @TypesFound = @TypesFound + 1;
IF @StatsCount > 0 SET @TypesFound = @TypesFound + 1;
IF @IntegrityCount > 0 SET @TypesFound = @TypesFound + 1;

SET @Score = CASE
    WHEN @TypesFound = 0 THEN 0
    WHEN @TypesFound = 1 THEN 1
    WHEN @TypesFound >= 2 THEN 2
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;