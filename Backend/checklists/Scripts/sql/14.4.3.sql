DECLARE @Score int;
DECLARE @Result nvarchar(10);
DECLARE @Finding nvarchar(max);
DECLARE @DatabaseQueried nvarchar(100) = 'master';

IF EXISTS (SELECT 1 FROM sys.resource_governor_configuration WHERE is_enabled = 1)
BEGIN
    SET @Score = 3;
    SET @Finding = 'Resource Governor is enabled.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = 'Resource Governor is disabled or not configured.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;