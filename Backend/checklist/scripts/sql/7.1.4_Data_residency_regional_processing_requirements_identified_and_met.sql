-- Checklist: Data residency / regional processing requirements identified and met
-- Scope: SERVER
-- Scoring: 0=No proxy evidence/evaluation failed; 1=Partial proxy evidence; 2=Full proxy evidence collected for human review; 3=Not achievable automatically (policy check caps at 2)

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #Evidence (
    Category NVARCHAR(50),
    Detail NVARCHAR(MAX)
);

-- Server Identity
INSERT INTO #Evidence (Category, Detail)
VALUES ('ServerName', CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256))),
       ('ComputerName', CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS NVARCHAR(256))),
       ('InstanceName', CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256))),
       ('IsClustered', CAST(SERVERPROPERTY('IsClustered') AS NVARCHAR(10))),
       ('EngineEdition', CAST(SERVERPROPERTY('EngineEdition') AS NVARCHAR(10)));

-- Cluster Nodes (if applicable)
IF CAST(SERVERPROPERTY('IsClustered') AS INT) = 1 AND OBJECT_ID('sys.dm_os_cluster_nodes') IS NOT NULL
BEGIN
    INSERT INTO #Evidence (Category, Detail)
    SELECT 'ClusterNode', node_name FROM sys.dm_os_cluster_nodes;
END

-- Availability Group Replicas (if applicable)
IF OBJECT_ID('sys.availability_replicas') IS NOT NULL
BEGIN
    INSERT INTO #Evidence (Category, Detail)
    SELECT 'AGReplica', replica_server_name FROM sys.availability_replicas;
END

-- Linked Servers
IF EXISTS (SELECT 1 FROM sys.servers WHERE server_id > 0)
BEGIN
    INSERT INTO #Evidence (Category, Detail)
    SELECT 'LinkedServer', name FROM sys.servers WHERE server_id > 0;
END

-- Database File Paths
INSERT INTO #Evidence (Category, Detail)
SELECT 'DbFilePath', physical_name FROM sys.master_files;

-- Aggregate findings
SET @Finding = (
    SELECT STRING_AGG(Category + ': ' + Detail, '; ')
    FROM #Evidence
);

IF @Finding IS NULL OR @Finding = ''
BEGIN
    SET @Score = 0;
    SET @Finding = 'No proxy evidence collected';
END
ELSE
BEGIN
    DECLARE @EvidenceCount INT = (SELECT COUNT(*) FROM #Evidence);
    IF @EvidenceCount >= 5
        SET @Score = 2;
    ELSE
        SET @Score = 1;
END

-- Policy check cap
IF @Score > 2 SET @Score = 2;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #Evidence;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding + ' -- NOTE: This script provides automated evidence. Full compliance requires human review.' AS Finding;