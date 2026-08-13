SET NOCOUNT ON;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @CredCount INT = 0;
DECLARE @JobCount INT = 0;
DECLARE @DBKeyCount INT = 0;
DECLARE @SQL NVARCHAR(MAX) = N'';

-- Check for server credentials (server-scoped)
SELECT @CredCount = COUNT(*) FROM sys.credentials;

-- Check for certificates, asymmetric keys, symmetric keys (database-scoped)
-- Iterate all online user databases to get a server-wide count
SELECT @SQL += N'SELECT @DBKeyCount = @DBKeyCount + COUNT(*) FROM ' + QUOTENAME(name) + N'.sys.certificates;
  SELECT @DBKeyCount = @DBKeyCount + COUNT(*) FROM ' + QUOTENAME(name) + N'.sys.asymmetric_keys;
  SELECT @DBKeyCount = @DBKeyCount + COUNT(*) FROM ' + QUOTENAME(name) + N'.sys.symmetric_keys;'
FROM sys.databases WHERE state = 0 AND database_id > 4;

BEGIN TRY
    IF LEN(@SQL) > 0
        EXEC sp_executesql @SQL, N'@DBKeyCount INT OUTPUT', @DBKeyCount = @DBKeyCount OUTPUT;
END TRY
BEGIN CATCH
    SET @DBKeyCount = 0;
END CATCH

SET @CredCount = @CredCount + @DBKeyCount;

-- Check for SQL Agent jobs related to rotation
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT @JobCount = COUNT(*)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE j.enabled = 1
      AND (
          j.name LIKE '%rotation%' OR j.name LIKE '%credential%' OR j.name LIKE '%key%' OR j.name LIKE '%secret%'
          OR js.command LIKE '%rotation%' OR js.command LIKE '%credential%' OR js.command LIKE '%key%' OR js.command LIKE '%secret%'
      );
END

IF @CredCount > 0 AND @JobCount > 0
    SET @Score = 2;
ELSE IF @CredCount > 0 AND @JobCount = 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;