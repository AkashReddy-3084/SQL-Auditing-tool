-- Checklist: Monitoring solution in place (Azure Monitor / SQL Insights / third-party)
-- Scope: SERVER
-- Scoring: 0=No indicators found; 1=Single weak indicator; 2=Multiple indicators (2-3, proxy evidence); 3=Official monitoring integration detected (e.g., SQL Insights/Azure Monitor XE session)

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

CREATE TABLE #Indicators (
    SourceType NVARCHAR(50),
    IndicatorName NVARCHAR(256),
    Details NVARCHAR(MAX)
);

-- Check Extended Event sessions (platform-adaptive)
IF @IsAzureSQLDB = 1
BEGIN
    INSERT INTO #Indicators (SourceType, IndicatorName, Details)
    SELECT 'DB_XE', name, 'Database Extended Event session'
    FROM sys.database_event_sessions
    WHERE name LIKE '%insight%' OR name LIKE '%monitor%' OR name LIKE '%performance%' OR name LIKE '%health%';
END
ELSE
BEGIN
    INSERT INTO #Indicators (SourceType, IndicatorName, Details)
    SELECT 'Server_XE', name, 'Server Extended Event session'
    FROM sys.server_event_sessions
    WHERE name LIKE '%insight%' OR name LIKE '%monitor%' OR name LIKE '%performance%' OR name LIKE '%health%';
END

-- Check SQL Agent Jobs (SQL Server / MI only)
IF @IsAzureSQLDB = 0
BEGIN
    INSERT INTO #Indicators (SourceType, IndicatorName, Details)
    SELECT 'Agent_Job', name, 'SQL Agent Job'
    FROM msdb.dbo.sysjobs
    WHERE name LIKE '%monitor%' OR name LIKE '%health%' OR name LIKE '%performance%' OR name LIKE '%insight%';
END

-- Check Schemas for known monitoring tools
INSERT INTO #Indicators (SourceType, IndicatorName, Details)
SELECT 'Schema', name, 'Monitoring tool schema'
FROM sys.schemas
WHERE name IN ('SolarWinds', 'Redgate', 'Datadog', 'AppDynamics', 'Dynatrace', 'NewRelic', 'AzureMonitor', 'SQLInsights');

-- Calculate score
DECLARE @Count INT = (SELECT COUNT(*) FROM #Indicators);
DECLARE @HasOfficial BIT = 0;
IF EXISTS (SELECT 1 FROM #Indicators WHERE IndicatorName LIKE '%SQLInsights%' OR IndicatorName LIKE '%AzureMonitor%') SET @HasOfficial = 1;

SET @Score = CASE
    WHEN @Count = 0 THEN 0
    WHEN @Count = 1 THEN 1
    WHEN @Count BETWEEN 2 AND 3 THEN 2
    WHEN @Count >= 4 OR @HasOfficial = 1 THEN 3
END;

-- Build finding
SET @Finding = ISNULL(
    (SELECT STRING_AGG(SourceType + ': ' + IndicatorName, '; ') FROM #Indicators),
    'No monitoring indicators found'
);

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #Indicators;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;