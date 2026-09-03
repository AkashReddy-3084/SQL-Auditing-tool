-- Checklist: Environment separation exists (Dev / Test / Prod) with isolated instances or databases
-- Scope: SERVER
-- Scoring: 3 = two or more distinct environment markers on databases and every user database classified; 2 = two or more database markers with some unclassified, or one database marker confirmed by the instance name; 1 = a single weak marker only; 0 = no environment marker found or no user database visible

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No environment-separation evidence was collected';
DECLARE @Server NVARCHAR(256) = ISNULL(CONVERT(NVARCHAR(256), SERVERPROPERTY('ServerName')), N'(unknown)');
DECLARE @ServerNorm NVARCHAR(400) = N'';
DECLARE @ServerEnv NVARCHAR(20) = N'none';
DECLARE @DbCount INT = 0;
DECLARE @EnvCount INT = 0;
DECLARE @Unknown INT = 0;
DECLARE @DevList NVARCHAR(MAX) = N'none';
DECLARE @TestList NVARCHAR(MAX) = N'none';
DECLARE @ProdList NVARCHAR(MAX) = N'none';
DECLARE @UnknownList NVARCHAR(MAX) = N'none';

SET @ServerNorm = LOWER(N' ' + REPLACE(REPLACE(REPLACE(REPLACE(@Server, N'_', N' '), N'-', N' '), N'\', N' '), N'.', N' ') + N' ');
SET @ServerEnv = CASE
    WHEN @ServerNorm LIKE N'% dev %' OR @ServerNorm LIKE N'% development %' THEN N'Dev'
    WHEN @ServerNorm LIKE N'% test %' OR @ServerNorm LIKE N'% qa %' OR @ServerNorm LIKE N'% uat %'
         OR @ServerNorm LIKE N'% stage %' OR @ServerNorm LIKE N'% staging %' THEN N'Test'
    WHEN @ServerNorm LIKE N'% prod %' OR @ServerNorm LIKE N'% production %' OR @ServerNorm LIKE N'% prd %' THEN N'Prod'
    ELSE N'none' END;

CREATE TABLE #Db (DbName SYSNAME NOT NULL, Env NVARCHAR(10) NOT NULL);

BEGIN TRY
    INSERT INTO #Db (DbName, Env)
    SELECT d.name,
           CASE WHEN n.nm LIKE N'% dev %' OR n.nm LIKE N'% development %' THEN N'Dev'
                WHEN n.nm LIKE N'% test %' OR n.nm LIKE N'% qa %' OR n.nm LIKE N'% uat %'
                     OR n.nm LIKE N'% stage %' OR n.nm LIKE N'% staging %' THEN N'Test'
                WHEN n.nm LIKE N'% prod %' OR n.nm LIKE N'% production %' OR n.nm LIKE N'% prd %' THEN N'Prod'
                ELSE N'Unknown' END
    FROM sys.databases AS d
    CROSS APPLY (SELECT LOWER(N' ' + REPLACE(REPLACE(REPLACE(REPLACE(d.name, N'_', N' '), N'-', N' '), N'\', N' '), N'.', N' ') + N' ') AS nm) AS n
    WHERE d.database_id > 4 AND d.state = 0;
END TRY
BEGIN CATCH
    SET @Finding = N'Unable to enumerate user databases: ' + ERROR_MESSAGE();
END CATCH;

SELECT @DbCount = COUNT(*),
       @Unknown = ISNULL(SUM(CASE WHEN Env = N'Unknown' THEN 1 ELSE 0 END), 0),
       @EnvCount = COUNT(DISTINCT CASE WHEN Env <> N'Unknown' THEN Env END)
FROM #Db;

SELECT @DevList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), N', '), 300), N'none') FROM #Db WHERE Env = N'Dev';
SELECT @TestList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), N', '), 300), N'none') FROM #Db WHERE Env = N'Test';
SELECT @ProdList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), N', '), 300), N'none') FROM #Db WHERE Env = N'Prod';
SELECT @UnknownList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), N', '), 300), N'none') FROM #Db WHERE Env = N'Unknown';

SET @Score = CASE
    WHEN @DbCount = 0 THEN 0
    WHEN @EnvCount >= 2 AND @Unknown = 0 THEN 3
    WHEN @EnvCount >= 2 THEN 2
    WHEN @EnvCount = 1 AND @ServerEnv <> N'none' THEN 2
    WHEN @EnvCount = 1 OR @ServerEnv <> N'none' THEN 1
    ELSE 0 END;

IF @DbCount > 0
    SET @Finding = CONCAT(N'Instance ', @Server, N' (instance name marker = ', @ServerEnv, N'); ',
        @DbCount, N' user database(s); distinct environment markers = ', @EnvCount,
        N'; Dev = ', @DevList, N'; Test/UAT = ', @TestList, N'; Prod = ', @ProdList,
        N'; unclassified = ', @UnknownList);
ELSE IF @Finding = N'No environment-separation evidence was collected'
    SET @Finding = CONCAT(N'No user database is visible on instance ', @Server,
        N' (instance name marker = ', @ServerEnv, N')');

DROP TABLE #Db;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
