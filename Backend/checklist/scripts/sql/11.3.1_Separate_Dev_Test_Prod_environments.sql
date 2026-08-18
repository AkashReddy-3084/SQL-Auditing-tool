-- Checklist: Separate Dev / Test / Prod environments
-- Scope: SERVER
-- Scoring: 3=Clear single environment keyword in server name; 2=Multiple/ambiguous keywords; 1=No keyword in server name but linked servers suggest separation; 0=No evidence of separation.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @ServerName NVARCHAR(256) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256));
DECLARE @UpperName NVARCHAR(256) = UPPER(@ServerName);
DECLARE @EnvKeywordCount INT = 0;

-- Count environment keywords in server name
IF @UpperName LIKE '%DEV%' SET @EnvKeywordCount += 1;
IF @UpperName LIKE '%TEST%' SET @EnvKeywordCount += 1;
IF @UpperName LIKE '%QA%' SET @EnvKeywordCount += 1;
IF @UpperName LIKE '%UAT%' SET @EnvKeywordCount += 1;
IF @UpperName LIKE '%STG%' SET @EnvKeywordCount += 1;
IF @UpperName LIKE '%PROD%' SET @EnvKeywordCount += 1;
IF @UpperName LIKE '%LIVE%' SET @EnvKeywordCount += 1;
IF @UpperName LIKE '%TRAIN%' SET @EnvKeywordCount += 1;
IF @UpperName LIKE '%DR%' SET @EnvKeywordCount += 1;

IF @EnvKeywordCount = 1
BEGIN
    SET @Score = 3;
    SET @Finding = 'Server name clearly indicates a dedicated environment: ' + @ServerName;
END
ELSE IF @EnvKeywordCount > 1
BEGIN
    SET @Score = 2;
    SET @Finding = 'Server name contains multiple environment keywords (' + @ServerName + '), suggesting ambiguous or shared environment configuration.';
END
ELSE
BEGIN
    -- Proxy check: linked servers
    DECLARE @LinkedEnvCount INT = 0;
    BEGIN TRY
        SELECT @LinkedEnvCount = COUNT(*) FROM sys.servers s
        WHERE UPPER(s.name) LIKE '%DEV%' OR UPPER(s.name) LIKE '%TEST%' OR UPPER(s.name) LIKE '%QA%' OR UPPER(s.name) LIKE '%UAT%' OR UPPER(s.name) LIKE '%STG%' OR UPPER(s.name) LIKE '%PROD%' OR UPPER(s.name) LIKE '%LIVE%';
    END TRY
    BEGIN CATCH
        SET @LinkedEnvCount = 0;
    END CATCH;

    IF @LinkedEnvCount > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'No environment keyword in server name (' + @ServerName + '), but ' + CAST(@LinkedEnvCount AS NVARCHAR(10)) + ' linked server(s) suggest environment separation.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No evidence of environment separation. Server name (' + @ServerName + ') lacks environment identifiers and no linked servers indicate separation.';
    END
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;