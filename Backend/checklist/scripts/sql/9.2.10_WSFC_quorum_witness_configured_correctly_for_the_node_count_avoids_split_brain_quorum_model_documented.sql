-- Checklist: 9.2.10 WSFC quorum / witness configured correctly for the node count (avoids split-brain); quorum model documented
-- Scope: SERVER
-- Scoring: 
-- 3: Quorum correctly configured for node count and documentation is confirmed (requires manual verification).
-- 2: Quorum correctly configured for node count, but documentation status is unverified.
-- 1: Quorum configuration is suboptimal (e.g., single node, or even nodes without witness).
-- 0: WSFC not enabled, quorum misconfigured, or not applicable.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @IsHadrEnabled INT;
DECLARE @EngineEdition INT;
DECLARE @NodeCount INT;
DECLARE @QuorumVoteCount INT;
DECLARE @WitnessVote INT;
DECLARE @WitnessName NVARCHAR(256);

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
SET @IsHadrEnabled = CONVERT(INT, SERVERPROPERTY('IsHadrEnabled'));
SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    SET @Score = 0;
    SET @Finding = 'WSFC is not applicable to Azure SQL Database. High availability is managed by the platform.';
END
ELSE IF @IsHadrEnabled = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'Always On Availability Groups (WSFC) is not enabled on this instance.';
END
ELSE
BEGIN
    SET @NodeCount = NULL;
    BEGIN TRY
        SELECT 
            @NodeCount = node_count,
            @QuorumVoteCount = quorum_vote_count,
            @WitnessVote = witness_vote,
            @WitnessName = witness_name
        FROM sys.dm_hadr_cluster_quorum;
    END TRY
    BEGIN CATCH
        SET @NodeCount = NULL;
    END CATCH;

    IF @NodeCount IS NULL OR @NodeCount = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'WSFC is enabled but quorum information is unavailable or cluster is not formed.';
    END
    ELSE IF @NodeCount = 1
    BEGIN
        SET @Score = 1;
        SET @Finding = CONCAT('Single-node cluster detected (NodeCount: ', @NodeCount, '). Not suitable for HA. Documentation requires manual verification.');
    END
    ELSE IF @NodeCount % 2 = 0 AND ISNULL(@WitnessVote, 0) = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = CONCAT('Even node count (', @NodeCount, ') without a witness. High risk of split-brain. Documentation requires manual verification.');
    END
    ELSE
    BEGIN
        SET @Score = 2;
        SET @Finding = CONCAT('NodeCount: ', @NodeCount, ', QuorumVotes: ', ISNULL(@QuorumVoteCount, 0), ', WitnessVote: ', ISNULL(@WitnessVote, 0), ', WitnessName: ', ISNULL(@WitnessName, 'None'), '. Configuration prevents split-brain. Documentation requires manual verification to achieve Score 3.');
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;