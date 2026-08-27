-- Checklist: Schema/object-level permissions align with least privilege
-- Scope: DATABASE
-- Scoring: 3 = guest CONNECT is not granted; 2 = guest CONNECT metadata is unavailable; 1 = guest CONNECT is granted; 0 = permission metadata could not be evaluated

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Guest permission metadata could not be evaluated';
DECLARE @GuestEnabled INT = 0;

BEGIN TRY
    SELECT @GuestEnabled = COUNT(*)
    FROM sys.database_permissions AS dp
    JOIN sys.database_principals AS u ON dp.grantee_principal_id = u.principal_id
    WHERE u.name = 'guest' AND dp.permission_name = 'CONNECT' AND dp.state = 'G';
    SET @Score = CASE WHEN @GuestEnabled = 0 THEN 3 ELSE 1 END;
    SET @Finding = N'guest_enabled=' + CONVERT(NVARCHAR(20), @GuestEnabled);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read guest permission metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;