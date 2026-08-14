-- Checklist: Separate Dev / Test / Prod environments
-- Scope: SERVER
-- Scoring: 0=No environment identifier, 1=Ambiguous/non-standard naming, 2=Clear environment keyword detected, 3=Capped at 2 (proxy evidence)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @ServerName NVARCHAR(256) = UPPER(COALESCE(TRY_CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(128)), @@SERVERNAME));
DECLARE @InstanceName NVARCHAR(256) = UPPER(COALESCE(TRY_CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(128)), N''));
DECLARE @FullIdentifier NVARCHAR(512) = @ServerName + N'\' + @InstanceName;

-- Check for clear environment keywords with approximate word-boundary matching
IF @FullIdentifier LIKE N'%[ _.-]DEV%' OR @FullIdentifier LIKE N'DEV%'
   OR @FullIdentifier LIKE N'%[ _.-]TEST%' OR @FullIdentifier LIKE N'TEST%'
   OR @FullIdentifier LIKE N'%[ _.-]PROD%' OR @FullIdentifier LIKE N'PROD%'
   OR @FullIdentifier LIKE N'%[ _.-]QA%' OR @FullIdentifier LIKE N'QA%'
   OR @FullIdentifier LIKE N'%[ _.-]UAT%' OR @FullIdentifier LIKE N'UAT%'
   OR @FullIdentifier LIKE N'%[ _.-]STG%' OR @FullIdentifier LIKE N'STG%'
BEGIN
    SET @Score = 2;
END
ELSE IF @FullIdentifier LIKE N'%[A-Z][A-Z]%' OR @FullIdentifier LIKE N'%[0-9]%'
BEGIN
    SET @Score = 1;
END
ELSE
BEGIN
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;