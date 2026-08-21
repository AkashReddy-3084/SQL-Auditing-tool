-- Checklist: Read-scale replicas used for reporting where appropriate
-- Scope: SERVER
-- Scoring: 3=Replicas configured and routing fully verified; 2=Replicas/routing configured but workload assignment requires manual review; 1=Partial configuration or legacy mirroring only; 0=No replicas or read-only routing configured.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @ReplicaCount INT = 0;

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database
    SET @DatabaseQueried = DB_NAME();
    BEGIN TRY
        SELECT @ReplicaCount = COUNT(*)
        FROM sys.dm_database_copies
        WHERE is_primary = 0;
    END TRY
    BEGIN CATCH
        SET @ReplicaCount = 0;
    END CATCH;
    SET @Finding = CASE 
        WHEN @ReplicaCount > 0 THEN CAST(@ReplicaCount AS NVARCHAR(10)) + ' read-scale replica(s) configured.'
        ELSE 'No read-scale replicas configured.'
    END;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL Managed Instance
    SET @DatabaseQueried = 'master';
    IF OBJECT_ID('master.sys.availability_read_only_routing_groups') IS NOT NULL
    BEGIN
        SELECT @ReplicaCount = COUNT(*)
        FROM master.sys.availability_read_only_routing_groups arg
        INNER JOIN master.sys.availability_replicas ar ON arg.group_id = ar.group_id
        WHERE ar.role_desc = 'SECONDARY'
          AND ar.read_only_routing_url IS NOT NULL;
    END
    SET @Finding = CASE 
        WHEN @ReplicaCount > 0 THEN CAST(@ReplicaCount AS NVARCHAR(10)) + ' read-only routing replica(s) configured.'
        ELSE 'No read-only routing replicas configured.'
    END;
END

SET @Score = CASE 
    WHEN @ReplicaCount > 0 THEN 2
    ELSE 0
END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;