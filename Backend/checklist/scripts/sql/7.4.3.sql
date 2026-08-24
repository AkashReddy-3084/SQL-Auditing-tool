DECLARE @Score INT = 0;
DECLARE @Result VARCHAR(20);
DECLARE @Finding VARCHAR(MAX) = '';
DECLARE @DatabaseQueried VARCHAR(128) = 'master';

DECLARE @TotalSpecs INT;
DECLARE @EnabledSpecs INT;
DECLARE @SensitiveDataSpecs INT;

SELECT 
    @TotalSpecs = COUNT(*),
    @EnabledSpecs = SUM(CASE WHEN sas.is_state_enabled = 1 THEN 1 ELSE 0 END),
    @SensitiveDataSpecs = SUM(CASE WHEN sas.is_state_enabled = 1 AND sad.audit_action_id IN ('SCHEMA_OBJECT_ACCESS_GROUP', 'DATABASE_OBJECT_ACCESS_GROUP') THEN 1 ELSE 0 END)
FROM sys.server_audit_specifications sas
LEFT JOIN sys.server_audit_specification_details sad ON sas.server_specification_id = sad.server_specification_id;

IF ISNULL(@TotalSpecs, 0) = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No server audit specifications found.';
END
ELSE IF ISNULL(@EnabledSpecs, 0) = 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Found ' + CAST(@TotalSpecs AS VARCHAR(10)) + ' server audit specifications, but none are enabled.';
END
ELSE IF ISNULL(@SensitiveDataSpecs, 0) = 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Enabled server audit specifications do not actively track object access groups.';
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = 'Enabled server audit specifications found tracking data/schema object access.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;