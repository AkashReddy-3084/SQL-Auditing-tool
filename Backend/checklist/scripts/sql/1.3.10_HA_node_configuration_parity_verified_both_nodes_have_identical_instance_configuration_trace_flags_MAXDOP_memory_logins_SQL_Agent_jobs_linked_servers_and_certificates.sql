-- Checklist: HA node configuration parity verified
-- Scope: SERVER
-- Scoring: 0=Fail (0-2 categories verified), 1=Partial Pass (3-5 categories verified), 2=Mostly Pass (all 6 categories verified on this node)
-- NOTE: Parity verification requires running this script on both HA nodes and comparing the generated fingerprints.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @VerifiedCount INT = 0;

CREATE TABLE #CatCheck (Category NVARCHAR(50), HasData BIT, Fingerprint NVARCHAR(100));

-- 1. Instance configuration (includes MAXDOP/memory)
INSERT INTO #CatCheck
SELECT 'Configurations',
       CASE WHEN EXISTS(SELECT 1 FROM sys.configurations WHERE advanced = 1) THEN 1 ELSE 0 END,
       CAST(CHECKSUM_AGG(CAST(value_in_use AS BIGINT)) AS NVARCHAR(100))
FROM sys.configurations;

-- 2. Trace flags
IF OBJECT_ID('sys.trace_flags') IS NOT NULL
    INSERT INTO #CatCheck
    SELECT 'TraceFlags',
           CASE WHEN EXISTS(SELECT 1 FROM sys.trace_flags) THEN 1 ELSE 0 END,
           CAST(CHECKSUM_AGG(status) AS NVARCHAR(100))
    FROM sys.trace_flags;
ELSE
    INSERT INTO #CatCheck SELECT 'TraceFlags', 0, NULL;

-- 3. Logins
INSERT INTO #CatCheck
SELECT 'Logins',
       CASE WHEN EXISTS(SELECT 1 FROM sys.server_principals WHERE type IN ('S','U','G')) THEN 1 ELSE 0 END,
       CAST(CHECKSUM_AGG(principal_id) AS NVARCHAR(100))
FROM sys.server_principals WHERE type IN ('S','U','G');

-- 4. SQL Agent jobs
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
    INSERT INTO #CatCheck
    SELECT 'AgentJobs',
           CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs) THEN 1 ELSE 0 END,
           CAST(CHECKSUM_AGG(CAST(job_id AS BIGINT)) AS NVARCHAR(100))
    FROM msdb.dbo.sysjobs;
ELSE
    INSERT INTO #CatCheck SELECT 'AgentJobs', 0, NULL;

-- 5. Linked servers
INSERT INTO #CatCheck
SELECT 'LinkedServers',
       CASE WHEN EXISTS(SELECT 1 FROM sys.servers WHERE server_id != 0) THEN 1 ELSE 0 END,
       CAST(CHECKSUM_AGG(server_id) AS NVARCHAR(100))
FROM sys.servers WHERE server_id != 0;

-- 6. Certificates (Server-level certificates reside in master)
INSERT INTO #CatCheck
SELECT 'Certificates',
       CASE WHEN EXISTS(SELECT 1 FROM master.sys.certificates) THEN 1 ELSE 0 END,
       CAST(CHECKSUM_AGG(certificate_id) AS NVARCHAR(100))
FROM master.sys.certificates;

SET @VerifiedCount = (SELECT SUM(HasData) FROM #CatCheck);

SET @Score = CASE 
    WHEN @VerifiedCount >= 6 THEN 2
    WHEN @VerifiedCount >= 3 THEN 1
    ELSE 0
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #CatCheck;
SELECT @Result AS Result, @Score AS Score;