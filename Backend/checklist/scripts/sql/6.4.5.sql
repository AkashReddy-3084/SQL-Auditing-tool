-- Checklist: Linked servers / external data sources use least-privilege, non-personal credentials
-- Scope: SERVER
-- Scoring: 3 = 100% of fixed-credential linked-server logins are not sysadmin (or none use fixed credentials); 2 = 50-99%; 1 = under 50%; 0 = no linked servers configured

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);
DECLARE @FixedCredCount INT, @NonSysadminFixedCredCount INT;

SELECT @FixedCredCount = COUNT(*)
FROM sys.linked_logins ll
JOIN sys.servers s ON s.server_id = ll.server_id
WHERE s.is_linked = 1 AND ll.uses_self_credential = 0 AND ll.local_principal_id <> 0;

SELECT @NonSysadminFixedCredCount = COUNT(*)
FROM sys.linked_logins ll
JOIN sys.servers s ON s.server_id = ll.server_id
JOIN sys.server_principals lp ON lp.principal_id = ll.local_principal_id
WHERE s.is_linked = 1 AND ll.uses_self_credential = 0 AND ll.local_principal_id <> 0
  AND NOT EXISTS (
      SELECT 1 FROM sys.server_role_members rm
      JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
      WHERE r.name = 'sysadmin' AND rm.member_principal_id = lp.principal_id
  );

SET @Score = CASE WHEN ISNULL(@FixedCredCount,0) = 0 THEN 3
                  WHEN @NonSysadminFixedCredCount = @FixedCredCount THEN 3
                  WHEN (CAST(ISNULL(@NonSysadminFixedCredCount,0) AS DECIMAL(9,4)) / NULLIF(@FixedCredCount,0)) >= 0.50 THEN 2
                  ELSE 1 END;
SET @Finding = CASE WHEN ISNULL(@FixedCredCount,0) = 0 THEN 'No linked servers use a fixed (non-self-credential) login mapping'
                    ELSE CONCAT('Fixed-credential linked-server logins = ', @FixedCredCount, ', not sysadmin = ', ISNULL(@NonSysadminFixedCredCount,0)) END;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;