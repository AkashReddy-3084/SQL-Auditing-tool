DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalJobs INT = 0;
DECLARE @DistinctOwners INT = 0;
DECLARE @MaxJobsPerOwner INT = 0;
DECLARE @MaxOwnerPct FLOAT = 0;
DECLARE @TotalHighPriv INT = 0;
DECLARE @JobScore INT = 0;
DECLARE @PrivScore INT = 0;

-- Check SQL Agent job ownership (on-prem/MI only; gracefully degrades for Azure SQL DB)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    CREATE TABLE #JobStats (OwnerSid VARBINARY(85), JobCount INT);
    INSERT INTO #JobStats
    SELECT owner_sid, COUNT(*)
    FROM msdb.dbo.sysjobs
    GROUP BY owner_sid;

    SELECT @TotalJobs = SUM(JobCount),
           @DistinctOwners = COUNT(*),
           @MaxJobsPerOwner = ISNULL(MAX(JobCount), 0)
    FROM #JobStats;

    SET @MaxOwnerPct = CASE WHEN @TotalJobs > 0 THEN CAST(@MaxJobsPerOwner AS FLOAT) / @TotalJobs ELSE 0 END;
    DROP TABLE #JobStats;
END

-- Check high-privilege distribution (sysadmin + db_owner)
CREATE TABLE #HighPrivSids (Sid VARBINARY(85));

-- Server-level sysadmin
INSERT INTO #HighPrivSids
SELECT sp.sid
FROM sys.server_role_members srm
JOIN sys.server_principals sp ON srm.member_principal_id = sp.principal_id
JOIN sys.server_principals srp ON srm.role_principal_id = srp.principal_id
WHERE srp.name = 'sysadmin';

-- Database-level db_owner across user DBs
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
    INSERT INTO #HighPrivSids
    SELECT p.sid
    FROM sys.database_role_members rm
    JOIN sys.database_principals p ON rm.member_principal_id = p.principal_id
    JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    WHERE r.name = ''db_owner'' AND p.type IN (''S'', ''U'', ''G'');';
    BEGIN TRY
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        -- Skip DBs where we lack permissions or encounter errors
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @TotalHighPriv = COUNT(DISTINCT Sid) FROM #HighPrivSids;
DROP TABLE #HighPrivSids;

-- Calculate Job Score (aligned with prompt)
IF @TotalJobs = 0 SET @JobScore = 2;
ELSE IF @DistinctOwners = 1 SET @JobScore = 0;
ELSE IF @MaxOwnerPct > 0.75 SET @JobScore = 1;
ELSE IF @MaxOwnerPct > 0.50 SET @JobScore = 2;
ELSE SET @JobScore = 3;

-- Calculate Privilege Score (aligned with prompt)
IF @TotalHighPriv <= 1 SET @PrivScore = 0;
ELSE IF @TotalHighPriv = 2 SET @PrivScore = 1;
ELSE IF @TotalHighPriv = 3 SET @PrivScore = 2;
ELSE SET @PrivScore = 3;

-- Final score is the minimum of both dimensions (worst-case)
SET @Score = CASE WHEN @JobScore < @PrivScore THEN @JobScore ELSE @PrivScore END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;