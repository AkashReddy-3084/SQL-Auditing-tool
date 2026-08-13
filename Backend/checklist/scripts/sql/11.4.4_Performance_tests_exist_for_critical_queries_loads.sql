-- Checklist: Performance tests exist for critical queries/loads
-- Scope: SERVER
-- Scoring: 0=No artifacts; 1=1-3 artifacts; 2=4+ artifacts; 3=Dedicated test schema found. Max capped at 2 due to proxy evidence.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalTestArtifacts INT = 0;
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Count INT;

CREATE TABLE #TestArtifacts (DbName NVARCHAR(256), ArtifactCount INT);

-- Check user databases for test procedures
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
    SELECT @Count = COUNT(*) FROM sys.procedures p
    WHERE p.name LIKE ''%perf%'' OR p.name LIKE ''%load%'' OR p.name LIKE ''%test%'' OR p.name LIKE ''%bench%'' OR p.name LIKE ''%stress%'';';
    
    BEGIN TRY
        EXEC sp_executesql @Sql, N'@Count INT OUTPUT', @Count OUTPUT;
        INSERT INTO #TestArtifacts VALUES (@DbName, @Count);
    END TRY
    BEGIN CATCH
        INSERT INTO #TestArtifacts VALUES (@DbName, 0);
    END CATCH;
    
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Check SQL Agent jobs for test jobs (on-prem / MI only; gracefully degrades in Azure SQL DB)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    INSERT INTO #TestArtifacts
    SELECT 'SQLAgent', COUNT(*) FROM msdb.dbo.sysjobs
    WHERE name LIKE '%perf%' OR name LIKE '%load%' OR name LIKE '%test%' OR name LIKE '%bench%' OR name LIKE '%stress%';
END

SELECT @TotalTestArtifacts = ISNULL(SUM(ArtifactCount), 0) FROM #TestArtifacts;

-- Assign score based on evidence volume
IF @TotalTestArtifacts = 0 SET @Score = 0;
ELSE IF @TotalTestArtifacts BETWEEN 1 AND 3 SET @Score = 1;
ELSE IF @TotalTestArtifacts >= 4 SET @Score = 2;
-- Score 3 reserved for explicit test framework metadata, but capped at 2 per proxy-evidence policy

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #TestArtifacts;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.