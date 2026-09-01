-- Checklist: Availability mode (synchronous vs asynchronous commit) and failover mode (automatic vs manual) documented and aligned to RPO/RTO
-- Scope: SERVER
-- Scoring: 3 = at least two synchronous-commit replicas with automatic failover and required_synchronized_secondaries_to_commit of 1 or more (RPO zero enforced), or Azure SQL Database platform-managed automatic failover; 2 = a synchronous-commit replica with automatic failover exists but no synchronised-commit requirement is enforced; 1 = an availability group exists with only asynchronous-commit or manual-failover replicas; 0 = no availability group configuration to align

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Availability and failover mode evidence could not be collected from this instance';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Groups INT = 0;
DECLARE @Replicas INT = 0;
DECLARE @SyncAuto INT = 0;
DECLARE @SyncManual INT = 0;
DECLARE @AsyncReplicas INT = 0;
DECLARE @RequiredSync INT = 0;
DECLARE @Modes NVARCHAR(600) = 'none';
DECLARE @Note NVARCHAR(300) = '';

IF @Edition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: availability mode and failover mode are not user-configurable; the service enforces synchronous local replica commit with automatic failover, and the RPO/RTO targets are fixed by the platform SLA.';
END
ELSE
BEGIN
    BEGIN TRY
        IF OBJECT_ID('sys.availability_replicas') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @a = (SELECT COUNT(*) FROM sys.availability_groups),
       @r = (SELECT COUNT(*) FROM sys.availability_replicas),
       @s = (SELECT COUNT(*) FROM sys.availability_replicas
             WHERE availability_mode_desc = ''SYNCHRONOUS_COMMIT'' AND failover_mode_desc = ''AUTOMATIC''),
       @t = (SELECT COUNT(*) FROM sys.availability_replicas
             WHERE availability_mode_desc = ''SYNCHRONOUS_COMMIT'' AND failover_mode_desc <> ''AUTOMATIC''),
       @y = (SELECT COUNT(*) FROM sys.availability_replicas
             WHERE availability_mode_desc = ''ASYNCHRONOUS_COMMIT''),
       @m = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(300), ar.replica_server_name + '' = ''
                           + ar.availability_mode_desc + ''/'' + ar.failover_mode_desc), ''; '')
                    FROM sys.availability_replicas AS ar), ''none'');';
            EXEC sp_executesql @Sql,
                 N'@a INT OUTPUT, @r INT OUTPUT, @s INT OUTPUT, @t INT OUTPUT, @y INT OUTPUT, @m NVARCHAR(600) OUTPUT',
                 @a = @Groups OUTPUT, @r = @Replicas OUTPUT, @s = @SyncAuto OUTPUT,
                 @t = @SyncManual OUTPUT, @y = @AsyncReplicas OUTPUT, @m = @Modes OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = ' Always On replica mode metadata was not readable.';
    END CATCH

    BEGIN TRY
        IF COL_LENGTH('sys.availability_groups', 'required_synchronized_secondaries_to_commit') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @q = ISNULL(MAX(required_synchronized_secondaries_to_commit), 0)
FROM sys.availability_groups;';
            EXEC sp_executesql @Sql, N'@q INT OUTPUT', @q = @RequiredSync OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = @Note + ' The synchronised-secondaries commit requirement was not readable.';
    END CATCH

    SET @Groups = ISNULL(@Groups, 0);
    SET @Replicas = ISNULL(@Replicas, 0);
    SET @SyncAuto = ISNULL(@SyncAuto, 0);
    SET @SyncManual = ISNULL(@SyncManual, 0);
    SET @AsyncReplicas = ISNULL(@AsyncReplicas, 0);
    SET @RequiredSync = ISNULL(@RequiredSync, 0);
    SET @Modes = ISNULL(@Modes, 'none');

    SET @Score = CASE
        WHEN @SyncAuto >= 2 AND @RequiredSync >= 1 THEN 3
        WHEN @SyncAuto >= 1 THEN 2
        WHEN @Groups > 0 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT('Availability groups = ', @Groups, ', replicas = ', @Replicas,
        '; synchronous-commit with automatic failover = ', @SyncAuto,
        ', synchronous-commit with manual failover = ', @SyncManual,
        ', asynchronous-commit = ', @AsyncReplicas,
        '; required_synchronized_secondaries_to_commit = ', @RequiredSync,
        '. Configured modes: ', @Modes, '.',
        CASE WHEN @Groups = 0
             THEN ' No availability group exists, so no availability or failover mode is set on this instance.'
             ELSE '' END,
        @Note);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
