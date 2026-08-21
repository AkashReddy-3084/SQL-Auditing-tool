SET NOCOUNT ON;

DECLARE @Result NVARCHAR(20);
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(4000) = N'';

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Collected BIT = 0;
DECLARE @ClusterName NVARCHAR(128) = NULL;
DECLARE @QuorumTypeDesc NVARCHAR(60) = NULL;
DECLARE @QuorumState INT = NULL;
DECLARE @QuorumStateDesc NVARCHAR(60) = NULL;
DECLARE @Nodes INT = 0;
DECLARE @UpNodes INT = 0;
DECLARE @Witnesses INT = 0;
DECLARE @VotingMembers INT = 0;
DECLARE @WitnessDesc NVARCHAR(1000) = N'none';

DECLARE @Cluster TABLE
(
    cluster_name      NVARCHAR(128) NULL,
    quorum_type       TINYINT       NULL,
    quorum_type_desc  NVARCHAR(60)  NULL,
    quorum_state      TINYINT       NULL,
    quorum_state_desc NVARCHAR(60)  NULL
);

DECLARE @Members TABLE
(
    member_name            NVARCHAR(128) NULL,
    member_type            TINYINT       NULL,
    member_type_desc       NVARCHAR(60)  NULL,
    member_state           TINYINT       NULL,
    member_state_desc      NVARCHAR(60)  NULL,
    number_of_quorum_votes INT           NULL
);

IF @EngineEdition IN (5, 6, 8, 9, 11)
BEGIN
    SET @Score = 0;
    SET @Finding = N'NOT APPLICABLE / MANUAL REVIEW: EngineEdition ' + CAST(@EngineEdition AS NVARCHAR(10))
                 + N' is a managed Azure SQL offering. Windows Server Failover Cluster quorum and witness configuration is owned by the platform and is not exposed to the customer, so this item cannot be assessed on this instance.';
END
ELSE
BEGIN
    -- DMVs are reached through sp_executesql so the batch still compiles on builds where they are absent.
    BEGIN TRY
        INSERT INTO @Cluster (cluster_name, quorum_type, quorum_type_desc, quorum_state, quorum_state_desc)
        EXEC sp_executesql N'SELECT cluster_name, quorum_type, quorum_type_desc, quorum_state, quorum_state_desc FROM sys.dm_hadr_cluster;';

        INSERT INTO @Members (member_name, member_type, member_type_desc, member_state, member_state_desc, number_of_quorum_votes)
        EXEC sp_executesql N'SELECT member_name, member_type, member_type_desc, member_state, member_state_desc, number_of_quorum_votes FROM sys.dm_hadr_cluster_members;';

        SET @Collected = 1;
    END TRY
    BEGIN CATCH
        SET @Collected = 0;
        SET @Score = 0;
        SET @Finding = N'MANUAL REVIEW: unable to read sys.dm_hadr_cluster / sys.dm_hadr_cluster_members. Error: '
                     + ISNULL(ERROR_MESSAGE(), N'(unknown)')
                     + N'. VIEW SERVER STATE permission and a WSFC-aware SQL Server build are required; verify the quorum model and witness manually in Failover Cluster Manager.';
    END CATCH;

    IF @Collected = 1
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM @Cluster)
        BEGIN
            SET @Score = 0;
            SET @Finding = N'NOT APPLICABLE / MANUAL REVIEW: sys.dm_hadr_cluster returned no rows, so this instance is not a node of a Windows Server Failover Cluster (no FCI and no WSFC-based availability group). WSFC quorum and witness configuration does not apply to this instance.';
        END
        ELSE
        BEGIN
            SELECT TOP (1)
                   @ClusterName     = cluster_name,
                   @QuorumTypeDesc  = quorum_type_desc,
                   @QuorumState     = quorum_state,
                   @QuorumStateDesc = quorum_state_desc
            FROM @Cluster;

            SELECT @Nodes         = ISNULL(SUM(CASE WHEN member_type = 0 THEN 1 ELSE 0 END), 0),
                   @UpNodes       = ISNULL(SUM(CASE WHEN member_type = 0 AND member_state = 1 THEN 1 ELSE 0 END), 0),
                   @Witnesses     = ISNULL(SUM(CASE WHEN member_type IN (1, 2, 3) THEN 1 ELSE 0 END), 0),
                   @VotingMembers = ISNULL(SUM(CASE WHEN ISNULL(number_of_quorum_votes, 0) > 0 THEN 1 ELSE 0 END), 0)
            FROM @Members;

            SELECT @WitnessDesc = ISNULL(
                       MAX(ISNULL(member_type_desc, N'witness')
                           + N' [' + ISNULL(member_name, N'(unnamed)')
                           + N', votes=' + CAST(ISNULL(number_of_quorum_votes, 0) AS NVARCHAR(10))
                           + N', state=' + ISNULL(member_state_desc, N'unknown') + N']'),
                       N'none')
            FROM @Members
            WHERE member_type IN (1, 2, 3);

            SET @Finding = N'Cluster ''' + ISNULL(@ClusterName, N'(unknown)')
                         + N''': quorum model = ' + ISNULL(@QuorumTypeDesc, N'(unknown)')
                         + N', quorum state = ' + ISNULL(@QuorumStateDesc, N'(unknown)')
                         + N'; WSFC nodes = ' + CAST(@Nodes AS NVARCHAR(10))
                         + N' (' + CAST(@UpNodes AS NVARCHAR(10)) + N' up)'
                         + N'; witness = ' + @WitnessDesc
                         + N'; members holding a quorum vote = ' + CAST(@VotingMembers AS NVARCHAR(10)) + N'.';

            IF @Nodes = 0
            BEGIN
                SET @Score = 0;
                SET @Finding = @Finding + N' MANUAL REVIEW: no WSFC node members are visible in sys.dm_hadr_cluster_members, so the vote layout cannot be evaluated; confirm the quorum model and witness manually.';
            END
            ELSE IF @QuorumState <> 1
            BEGIN
                SET @Score = 0;
                SET @Finding = @Finding + N' Quorum is not in the normal state (forced or unknown quorum), so the cluster is currently running without a healthy quorum and is exposed to split-brain and unplanned outage.';
            END
            ELSE IF @VotingMembers % 2 = 0
            BEGIN
                SET @Score = 1;
                SET @Finding = @Finding + N' Quorum is normal but the total number of voting members is even'
                             + CASE WHEN @Witnesses = 0 THEN N' and no disk, file share or cloud witness is configured' ELSE N'' END
                             + N', so the cluster cannot break a tie and is exposed to split-brain. Add or remove a witness vote so the total vote count is odd for the current node count, and document the resulting quorum model.';
            END
            ELSE IF @UpNodes < @Nodes
            BEGIN
                SET @Score = 2;
                SET @Finding = @Finding + N' The vote layout is correct (normal quorum with an odd total vote count for this node count), but ' + CAST(@Nodes - @UpNodes AS NVARCHAR(10))
                             + N' node member(s) are not up, so the cluster is running with reduced fault tolerance. Restore the offline node(s) and confirm the documented quorum model.';
            END
            ELSE
            BEGIN
                SET @Score = 3;
                SET @Finding = @Finding + N' Quorum is normal, every node member is up and the total number of voting members is odd, which is the correct vote layout for this node count and prevents a tie. The existence of written quorum-model documentation is outside the scope of this script and should be confirmed manually.';
            END
        END
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;