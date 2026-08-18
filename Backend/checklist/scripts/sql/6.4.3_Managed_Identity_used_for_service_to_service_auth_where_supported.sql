-- Checklist: Managed Identity used for service-to-service auth where supported
-- Scope: SERVER
-- Scoring: 0: No MI credentials found or legacy auth dominates. 1: Some MI credentials found but legacy auth is prevalent. 2: Majority of auth mechanisms use MI or no auth mechanisms found. 3: All supported service-to-service auth mechanisms use MI.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @MiCount INT = 0;
DECLARE @TotalCount INT = 0;
DECLARE @LegacyCount INT = 0;
DECLARE @HasCredentials BIT = 0;

-- Check if sys.credentials is available (not available in Azure SQL Database)
IF OBJECT_ID('sys.credentials') IS NOT NULL
BEGIN
    SET @HasCredentials = 1;
    SELECT @MiCount = COUNT(*) FROM sys.credentials WHERE credential_identity LIKE '%Managed%';
    SELECT @TotalCount = COUNT(*) FROM sys.credentials;
END

-- Check linked servers using self credential (often implies MI or Windows auth)
SELECT @MiCount = @MiCount + COUNT(*) FROM sys.linked_servers WHERE uses_self_credential = 1;
SELECT @TotalCount = @TotalCount + COUNT(*) FROM sys.linked_servers;

-- Determine score based on evidence
IF @TotalCount = 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'No service-to-service credentials or linked servers found. No legacy authentication detected.';
END
ELSE
BEGIN
    SET @LegacyCount = @TotalCount - @MiCount;
    
    IF @MiCount = @TotalCount
        SET @Score = 3;
    ELSE IF @MiCount > @LegacyCount
        SET @Score = 2;
    ELSE IF @MiCount > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Finding = CONCAT('Total service-to-service auth mechanisms: ', @TotalCount, '. Managed Identity: ', @MiCount, '. Legacy/Password-based: ', @LegacyCount, '.');
    
    IF @HasCredentials = 0
        SET @Finding = @Finding + ' NOTE: sys.credentials is not available on this platform; evaluation based on linked servers only.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;