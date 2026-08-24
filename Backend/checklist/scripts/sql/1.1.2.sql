-- Checklist: Environment separation exists (Dev / Test / Prod) with isolated instances or databases
-- Scope: SERVER
-- Scoring: 3 = all three environments isolated; 2 = strong partial evidence; 1 = minimal or ambiguous evidence; 0 = no evidence
-- NOTE: Automated evidence only; full compliance requires human review when the score is below 3.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Environment separation evidence was not found';
DECLARE @ServerName NVARCHAR(256) = CONVERT(NVARCHAR(256), SERVERPROPERTY('ServerName'));
DECLARE @NormalizedServer NVARCHAR(300);
DECLARE @DatabaseCount INT = 0;
DECLARE @DatabaseEnvironmentCount INT = 0;
DECLARE @ServerEnvironmentCount INT = 0;
DECLARE @AmbiguousCount INT = 0;
DECLARE @UnclassifiedCount INT = 0;
DECLARE @DevDatabases NVARCHAR(MAX);
DECLARE @TestDatabases NVARCHAR(MAX);
DECLARE @ProdDatabases NVARCHAR(MAX);
DECLARE @UnclassifiedDatabases NVARCHAR(MAX);
DECLARE @ServerMarkers NVARCHAR(MAX);

CREATE TABLE #Databases (DbName SYSNAME NOT NULL, NormalizedName NVARCHAR(300) NOT NULL);
CREATE TABLE #EnvironmentEvidence
(
    ObjectType NVARCHAR(10) NOT NULL,
    ObjectName NVARCHAR(256) NOT NULL,
    EnvironmentName NVARCHAR(10) NOT NULL
);

SET @NormalizedServer = LOWER(N' ' + REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
    ISNULL(@ServerName, N''), N'_', N' '), N'-', N' '), N'.', N' '), N'\', N' '), N'/', N' ') + N' ');

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #Databases (DbName, NormalizedName)
    SELECT DB_NAME(), LOWER(N' ' + REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
        DB_NAME(), N'_', N' '), N'-', N' '), N'.', N' '), N'\', N' '), N'/', N' ') + N' ');
END
ELSE
BEGIN
    INSERT INTO #Databases (DbName, NormalizedName)
    SELECT name, LOWER(N' ' + REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
        name, N'_', N' '), N'-', N' '), N'.', N' '), N'\', N' '), N'/', N' ') + N' ')
    FROM sys.databases
    WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;
END

INSERT INTO #EnvironmentEvidence (ObjectType, ObjectName, EnvironmentName)
SELECT 'Database', DbName, 'Dev' FROM #Databases
WHERE NormalizedName LIKE N'% dev %' OR NormalizedName LIKE N'% development %';

INSERT INTO #EnvironmentEvidence (ObjectType, ObjectName, EnvironmentName)
SELECT 'Database', DbName, 'Test' FROM #Databases
WHERE NormalizedName LIKE N'% test %' OR NormalizedName LIKE N'% qa %'
   OR NormalizedName LIKE N'% uat %' OR NormalizedName LIKE N'% stage %'
   OR NormalizedName LIKE N'% staging %';

INSERT INTO #EnvironmentEvidence (ObjectType, ObjectName, EnvironmentName)
SELECT 'Database', DbName, 'Prod' FROM #Databases
WHERE NormalizedName LIKE N'% prod %' OR NormalizedName LIKE N'% production %';

INSERT INTO #EnvironmentEvidence (ObjectType, ObjectName, EnvironmentName)
SELECT 'Server', ISNULL(@ServerName, N'(unknown)'), EnvironmentName
FROM (VALUES
    ('Dev', CASE WHEN @NormalizedServer LIKE N'% dev %' OR @NormalizedServer LIKE N'% development %' THEN 1 ELSE 0 END),
    ('Test', CASE WHEN @NormalizedServer LIKE N'% test %' OR @NormalizedServer LIKE N'% qa %'
                  OR @NormalizedServer LIKE N'% uat %' OR @NormalizedServer LIKE N'% stage %'
                  OR @NormalizedServer LIKE N'% staging %' THEN 1 ELSE 0 END),
    ('Prod', CASE WHEN @NormalizedServer LIKE N'% prod %' OR @NormalizedServer LIKE N'% production %' THEN 1 ELSE 0 END)
) AS markers(EnvironmentName, IsPresent)
WHERE IsPresent = 1;

SELECT @DatabaseCount = COUNT(*) FROM #Databases;
SELECT @DatabaseEnvironmentCount = COUNT(DISTINCT EnvironmentName)
FROM #EnvironmentEvidence WHERE ObjectType = 'Database';
SELECT @ServerEnvironmentCount = COUNT(DISTINCT EnvironmentName)
FROM #EnvironmentEvidence WHERE ObjectType = 'Server';
SELECT @AmbiguousCount = COUNT(*) FROM
(
    SELECT ObjectName FROM #EnvironmentEvidence
    WHERE ObjectType = 'Database' GROUP BY ObjectName HAVING COUNT(DISTINCT EnvironmentName) > 1
) AS ambiguous;
SELECT @UnclassifiedCount = COUNT(*) FROM #Databases AS d
WHERE NOT EXISTS (SELECT 1 FROM #EnvironmentEvidence AS e
                  WHERE e.ObjectType = 'Database' AND e.ObjectName = d.DbName);

SELECT @DevDatabases = STRING_AGG(CONVERT(NVARCHAR(MAX), ObjectName), N', ')
FROM #EnvironmentEvidence WHERE ObjectType = 'Database' AND EnvironmentName = 'Dev';
SELECT @TestDatabases = STRING_AGG(CONVERT(NVARCHAR(MAX), ObjectName), N', ')
FROM #EnvironmentEvidence WHERE ObjectType = 'Database' AND EnvironmentName = 'Test';
SELECT @ProdDatabases = STRING_AGG(CONVERT(NVARCHAR(MAX), ObjectName), N', ')
FROM #EnvironmentEvidence WHERE ObjectType = 'Database' AND EnvironmentName = 'Prod';
SELECT @UnclassifiedDatabases = STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), N', ')
FROM #Databases AS d WHERE NOT EXISTS
    (SELECT 1 FROM #EnvironmentEvidence AS e WHERE e.ObjectType = 'Database' AND e.ObjectName = d.DbName);
SELECT @ServerMarkers = STRING_AGG(CONVERT(NVARCHAR(MAX), EnvironmentName), N', ')
FROM #EnvironmentEvidence WHERE ObjectType = 'Server';

SET @Score = CASE
    WHEN @DatabaseCount = 0 THEN 0
    WHEN @AmbiguousCount > 0 THEN 1
    WHEN @DatabaseEnvironmentCount = 3 AND @UnclassifiedCount = 0 THEN 3
    WHEN @DatabaseEnvironmentCount >= 2 THEN 2
    WHEN @DatabaseEnvironmentCount = 1 AND @ServerEnvironmentCount = 1
         AND EXISTS
         (
             SELECT 1
             FROM #EnvironmentEvidence AS database_evidence
             JOIN #EnvironmentEvidence AS server_evidence
               ON server_evidence.EnvironmentName = database_evidence.EnvironmentName
              AND server_evidence.ObjectType = 'Server'
             WHERE database_evidence.ObjectType = 'Database'
         ) THEN 2
    WHEN @DatabaseEnvironmentCount > 0 OR @ServerEnvironmentCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CASE WHEN @DatabaseCount = 0 THEN 'No online user database found to inspect'
    ELSE CONCAT('Server = ', ISNULL(@ServerName, N'(unknown)'),
        '; server markers = ', ISNULL(@ServerMarkers, N'none'),
        '; Dev databases = ', ISNULL(@DevDatabases, N'none'),
        '; Test databases = ', ISNULL(@TestDatabases, N'none'),
        '; Prod databases = ', ISNULL(@ProdDatabases, N'none'),
        '; unclassified databases = ', ISNULL(@UnclassifiedDatabases, N'none'),
        '; ambiguous database count = ', @AmbiguousCount)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;