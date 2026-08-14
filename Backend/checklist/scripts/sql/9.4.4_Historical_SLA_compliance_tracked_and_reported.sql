-- Checklist: Historical SLA compliance tracked and reported
-- Scope: SERVER
-- Scoring: 0=No evidence found, 1=Minimal/indirect references found, 2=Dedicated tracking tables/jobs found, 3=Fully automated SLA reporting suite (proxy scan caps at 2)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalMatches INT = 0;
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), MatchCount INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT COUNT(*) FROM (
            SELECT name FROM sys.tables WHERE name LIKE ''%SLA%'' OR name LIKE ''%compliance%'' OR name LIKE ''%downtime%'' OR name LIKE ''%uptime%''
            UNION ALL
            SELECT name FROM sys.views WHERE name LIKE ''%SLA%'' OR name LIKE ''%compliance%'' OR name LIKE ''%report%''
            UNION ALL
            SELECT name FROM sys.procedures WHERE name LIKE ''%SLA%'' OR name LIKE ''%compliance%'' OR name LIKE ''%report%''
        ) AS T;';
        INSERT INTO #DbResults (DbName, MatchCount)
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @TotalMatches = ISNULL(SUM(MatchCount), 0) FROM #DbResults;

-- Check SQL Agent jobs for SLA reporting (on-prem/MI only)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE '%SLA%' OR name LIKE '%compliance%' OR name LIKE '%report%')
        SET @TotalMatches = @TotalMatches + 5;
END

SET @Score = CASE 
    WHEN @TotalMatches = 0 THEN 0
    WHEN @TotalMatches BETWEEN 1 AND 2 THEN 1
    WHEN @TotalMatches BETWEEN 3 AND 9 THEN 2
    ELSE 2
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.