DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @ServerName NVARCHAR(128) = @@SERVERNAME;
DECLARE @TotalRefs INT = 0;
DECLARE @SingleNodeRefs INT = 0;
DECLARE @IsAzure BIT = CASE WHEN SERVERPROPERTY('EngineEdition') IN (5, 8) THEN 1 ELSE 0 END;

-- Count references in sys.servers (linked servers)
SELECT @TotalRefs = @TotalRefs + COUNT(*),
       @SingleNodeRefs = @SingleNodeRefs + ISNULL(SUM(CASE WHEN data_source = @ServerName OR prov_str LIKE '%' + @ServerName + '%' THEN 1 ELSE 0 END), 0)
FROM sys.servers
WHERE data_source IS NOT NULL OR prov_str IS NOT NULL;

-- Count references in msdb.dbo.sysjobsteps (SQL Agent job commands)
-- Skipped for Azure SQL DB (EngineEdition 5) where msdb is not accessible
IF SERVERPROPERTY('EngineEdition') <> 5
BEGIN
    SELECT @TotalRefs = @TotalRefs + COUNT(*),
           @SingleNodeRefs = @SingleNodeRefs + ISNULL(SUM(CASE WHEN command LIKE '%Server=' + @ServerName + '%' OR command LIKE '%Data Source=' + @ServerName + '%' OR command LIKE '%-S ' + @ServerName + '%' THEN 1 ELSE 0 END), 0)
    FROM msdb.dbo.sysjobsteps
    WHERE command LIKE '%Server=%' OR command LIKE '%Data Source=%' OR command LIKE '%-S %';
END

-- Determine score
IF @IsAzure = 1
    SET @Score = 3;
ELSE IF @TotalRefs = 0
    SET @Score = 0;
ELSE IF @SingleNodeRefs = @TotalRefs
    SET @Score = 0;
ELSE IF CAST(@SingleNodeRefs AS FLOAT) / @TotalRefs > 0.5
    SET @Score = 1;
ELSE
    SET @Score = 2;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;