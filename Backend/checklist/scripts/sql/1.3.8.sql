SET NOCOUNT ON;

DECLARE @Score int = 3;
DECLARE @DatabaseQueried nvarchar(128) = DB_NAME();
DECLARE @Finding nvarchar(max) = '';
DECLARE @Violations int = 0;
DECLARE @FailedDBs table (db_name sysname);
DECLARE @Result nvarchar(50);

INSERT INTO @FailedDBs (db_name)
SELECT name
FROM sys.databases
WHERE is_trustworthy_on = 1
  AND name != 'msdb';

SELECT @Violations = COUNT(*) FROM @FailedDBs;

IF @Violations > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'The following databases have the Trustworthy property set to ON: ' + 
        (SELECT STRING_AGG(CAST(db_name AS nvarchar(max)), ', ') FROM @FailedDBs) + '.';
END
ELSE
BEGIN
    SET @Finding = 'All user databases have the Trustworthy property set to OFF.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT 
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;