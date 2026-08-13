-- Checklist: Data residency / regional processing requirements identified and met
-- Scope: SERVER
-- Scoring: 0=No region indicators found; 1=Single indicator found (hostname OR file path OR Azure location); 2=Two or more consistent indicators found across server name, file paths, and/or Azure metadata; 3=Reserved for explicit infrastructure verification (T-SQL maxes at 2 for proxy evidence)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @ServerName NVARCHAR(256);
DECLARE @HostnameRegion INT = 0;
DECLARE @AzureLocation NVARCHAR(100) = NULL;
DECLARE @FileRegionCount INT = 0;

-- 1. Check server name/hostname for region codes
SET @ServerName = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256));
IF @ServerName LIKE '%us%' OR @ServerName LIKE '%eu%' OR @ServerName LIKE '%apac%' OR @ServerName LIKE '%asia%' OR @ServerName LIKE '%america%' OR @ServerName LIKE '%[A-Z][A-Z]%'
    SET @HostnameRegion = 1;

-- 2. Check Azure location metadata if available (Azure SQL DB / MI)
IF OBJECT_ID('sys.database_service_objectives') IS NOT NULL
BEGIN
    SELECT TOP 1 @AzureLocation = 'Azure' FROM sys.database_service_objectives;
END
ELSE IF OBJECT_ID('sys.server_service_objectives') IS NOT NULL
BEGIN
    SELECT TOP 1 @AzureLocation = 'Azure' FROM sys.server_service_objectives;
END

-- 3. Check database file paths for region indicators (server-level view)
SELECT @FileRegionCount = COUNT(*)
FROM master.sys.master_files
WHERE physical_name IS NOT NULL
   AND (physical_name LIKE '%us%' OR physical_name LIKE '%eu%' OR physical_name LIKE '%apac%' OR physical_name LIKE '%asia%' OR physical_name LIKE '%america%');

-- Calculate score based on evidence count
DECLARE @EvidenceCount INT = @HostnameRegion + CASE WHEN @AzureLocation IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN @FileRegionCount > 0 THEN 1 ELSE 0 END;

IF @EvidenceCount >= 2 SET @Score = 2;
ELSE IF @EvidenceCount = 1 SET @Score = 1;
ELSE SET @Score = 0;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;