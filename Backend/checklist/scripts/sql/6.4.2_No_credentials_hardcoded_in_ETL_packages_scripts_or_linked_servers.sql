-- Checklist: No credentials hardcoded in ETL packages, scripts, or linked servers
-- Scope: SERVER
-- Scoring: 0=Hardcoded creds in linked servers/job steps; 1=Potential matches in scripts only; 2=Clean but partial scan coverage; 3=No matches across all artifacts
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @LinkedCount INT = 0;
DECLARE @JobCount INT = 0;
DECLARE @ScriptCount INT = 0;
DECLARE @SkippedDbCount INT = 0;

CREATE TABLE #Matches (Source NVARCHAR(128), ObjectName NVARCHAR(256), MatchText NVARCHAR(100));

-- 1. Linked Servers (On-prem / MI only)
IF OBJECT_ID('sys.servers') IS NOT NULL AND OBJECT_ID('sys.linked_logins') IS NOT NULL
BEGIN
    INSERT INTO #Matches
    SELECT 'LinkedServer', s.name, 'Hardcoded password in linked login'
    FROM sys.servers s
    JOIN sys.linked_logins l ON s.server_id = l.server_id
    WHERE l.password IS NOT NULL AND LTRIM(RTRIM(l.password)) <> '';
END

-- 2. SQL Agent Job Steps (On-prem / MI only)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    INSERT INTO #Matches
    SELECT 'JobStep', j.name, 'Potential credential in command'
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE js.command LIKE '%password%' OR js.command LIKE '%pwd%' OR js.command LIKE '%secret%' OR js.command LIKE '%key%' OR js.command LIKE '%user id%' OR js.command LIKE '%uid%';
END

-- 3. T-SQL Modules across user databases
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #Matches
        SELECT ''Script'', OBJECT_NAME(object_id), ''Potential credential in definition''
        FROM sys.sql_modules
        WHERE definition LIKE ''%password%'' OR definition LIKE ''%pwd%'' OR definition LIKE ''%secret%'' OR definition LIKE ''%key%'' OR definition LIKE ''%user id%'' OR definition LIKE ''%uid%'';';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @SkippedDbCount = @SkippedDbCount + 1;
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @LinkedCount = COUNT(*) FROM #Matches WHERE Source = 'LinkedServer';
SELECT @JobCount = COUNT(*) FROM #Matches WHERE Source = 'JobStep';
SELECT @ScriptCount = COUNT(*) FROM #Matches WHERE Source = 'Script';

IF @LinkedCount > 0 OR @JobCount > 0
    SET @Score = 0;
ELSE IF @ScriptCount > 0
    SET @Score = 1;
ELSE IF @SkippedDbCount > 0
    SET @Score = 2;
ELSE
    SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #Matches;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review of any flagged script matches.