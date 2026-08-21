-- Checklist: Reporting workloads isolated from write workloads (read replicas) where possible
-- Scope: SERVER
-- Scoring: 3 = Secondary replica with read-intent enabled; 2 = Secondary replica without read-intent; 1 = Primary replica (no isolation); 0 = Not in AG/Unknown

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Not part of an Availability Group';

DECLARE @IsSecondary BIT = 0;
DECLARE @ReadIntentEnabled BIT = 0;

BEGIN TRY
    -- Check if this instance is a secondary replica
    IF EXISTS (
        SELECT 1 
        FROM sys.dm_hadr_database_replica_states 
        WHERE is_local = 1 AND role = 2 -- 2 = Secondary
    )
    BEGIN
        SET @IsSecondary = 1;
    END

    -- Check if read-intent is enabled on the secondary
    -- secondary_role: 0 = None, 1 = Read-intent only, 2 = All
    IF EXISTS (
        SELECT 1 
        FROM sys.availability_replicas ar
        WHERE ar.replica_server_name = CAST(SERVERPROPERTY('MachineName') AS SYSNAME)
        AND ar.secondary_role IN (1, 2)
    )
    BEGIN
        SET @ReadIntentEnabled = 1;
    END
END TRY
BEGIN CATCH
    SET @Finding = 'Error evaluating replica state: ' + ERROR_MESSAGE();
END CATCH

IF @IsSecondary = 1
BEGIN
    IF @ReadIntentEnabled = 1
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Instance is a secondary replica with read-intent enabled (Reporting isolated)';
    END
    ELSE
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Instance is a secondary replica, but read-intent is not enabled';
    END
END
ELSE
BEGIN
    -- Check if it is a primary replica
    IF EXISTS (
        SELECT 1 
        FROM sys.dm_hadr_database_replica_states 
        WHERE is_local = 1 AND role = 1 -- 1 = Primary
    )
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Instance is the primary replica (Write workloads present)';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'Instance is not part of an Availability Group';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;