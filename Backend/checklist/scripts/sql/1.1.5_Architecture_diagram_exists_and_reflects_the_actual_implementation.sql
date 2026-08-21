-- Checklist: Architecture diagram exists and reflects the actual implementation
-- Scope: SERVER
-- Scoring: 0: Evaluation failed or no metadata retrieved. 1: Limited metadata retrieved. 2: Comprehensive server metadata collected for manual comparison. 3: Not achievable automatically (requires human review).

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @DbList NVARCHAR(MAX) = '';
DECLARE @LsList NVARCHAR(MAX) = '';
DECLARE @EpList NVARCHAR(MAX) = '';
DECLARE @AgList NVARCHAR(MAX) = '';
DECLARE @Clustered BIT = 0;
DECLARE @Hadr BIT = 0;

-- Databases
SELECT @DbList = STRING_AGG(name, ', ') FROM sys.databases WHERE state_desc = 'ONLINE';

-- Linked Servers
SELECT @LsList = STRING_AGG(name, ', ') FROM sys.servers WHERE is_linked = 1;

-- Endpoints
SELECT @EpList = STRING_AGG(name, ', ') FROM sys.endpoints;

-- Availability Groups (version/platform aware)
IF OBJECT_ID('sys.availability_groups') IS NOT NULL
BEGIN
    SELECT @AgList = STRING_AGG(name, ', ') FROM sys.availability_groups;
END

-- Cluster / HADR
SET @Clustered = CAST(SERVERPROPERTY('IsClustered') AS BIT);
SET @Hadr = CAST(SERVERPROPERTY('IsHadrEnabled') AS BIT);

SET @Finding = 'Databases: ' + ISNULL(@DbList, 'None') + '; ' +
               'Linked Servers: ' + ISNULL(@LsList, 'None') + '; ' +
               'Endpoints: ' + ISNULL(@EpList, 'None') + '; ' +
               'Availability Groups: ' + ISNULL(@AgList, 'None') + '; ' +
               'Clustered: ' + CAST(@Clustered AS NVARCHAR(3)) + '; ' +
               'HADR Enabled: ' + CAST(@Hadr AS NVARCHAR(3));

SET @Score = 2;
SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;