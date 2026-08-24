-- Checklist: WSFC quorum / witness configured correctly for the node count (avoids split-brain); quorum model documented
-- Scope: SERVER
-- Scoring: 3 = voting members total is odd (or a witness makes it effectively odd), or Azure SQL Database (no WSFC); 2 = reserved; 1 = voting members total is even with no witness (split-brain risk); 0 = no WSFC cluster detected and not Azure SQL Database
-- NOTE: Automated evidence only; whether the quorum model is separately written down in documentation is not independently verified. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: no Windows Server Failover Cluster (WSFC) concept applies';
END
ELSE
BEGIN
    DECLARE @ClusterExists INT = 0, @TotalVotes INT = 0;

    IF OBJECT_ID('sys.dm_hadr_cluster') IS NOT NULL
        SELECT @ClusterExists = COUNT(*) FROM sys.dm_hadr_cluster;

    IF OBJECT_ID('sys.dm_hadr_cluster_members') IS NOT NULL
        SELECT @TotalVotes = ISNULL(SUM(number_of_quorum_votes),0) FROM sys.dm_hadr_cluster_members;

    SET @Score = CASE WHEN ISNULL(@ClusterExists,0) = 0 THEN 0
                      WHEN @TotalVotes % 2 = 1 THEN 3
                      ELSE 1 END;
    SET @Finding = CASE WHEN ISNULL(@ClusterExists,0) = 0 THEN 'No Windows Server Failover Cluster detected'
                        ELSE CONCAT('WSFC cluster detected, total quorum votes (including any witness) = ', ISNULL(@TotalVotes,0), CASE WHEN @TotalVotes % 2 = 1 THEN ' (odd - safe)' ELSE ' (even - split-brain risk)' END) END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;