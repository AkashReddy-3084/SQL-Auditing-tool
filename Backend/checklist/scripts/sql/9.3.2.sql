-- Checklist: Page verification set to CHECKSUM
-- Scope: SERVER
-- Scoring: 3 = CHECKSUM (1); 2 = platform managed; 1 = SIMPLE (0); 0 = value unavailable

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Setting could not be read';
DECLARE @Value INT;

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: page verification is managed by the platform';
END
ELSE
BEGIN
    SELECT @Value = CONVERT(INT, value_in_use)
    FROM sys.configurations
    WHERE name = 'page verification';

    IF @Value = 1
    BEGIN
        SET @Score = 3;
        SET @Finding = 'page verification = 1 (CHECKSUM)';
    END
    ELSE IF @Value = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'page verification = 0 (SIMPLE)';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'page verification = ' + CAST(ISNULL(@Value, 0) AS NVARCHAR(10)) + ' (Unknown/Non-compliant)';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;