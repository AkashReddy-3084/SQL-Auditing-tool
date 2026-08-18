-- Checklist: Server/database topology documented (instances, databases, elastic pools)
-- Scope: SERVER
-- Scoring: 0=Failed to gather inventory, 1=Partial inventory (instance only), 2=Complete inventory gathered (proxy for documentation), 3=Not applicable for proxy checks.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @ServerName NVARCHAR(256);
DECLARE @DbList NVARCHAR(MAX);
DECLARE @PoolList NVARCHAR(MAX);
DECLARE @EngineEdition INT;

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
SET @ServerName = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256));

-- Gather database list
SELECT @DbList = STRING_AGG(name, ', ')
FROM sys.databases
WHERE database_id > 4 AND state = 0;

-- Gather elastic pool list (Azure SQL DB/MI)
IF @EngineEdition IN (5, 8)
BEGIN
    SELECT @PoolList = STRING_AGG(DISTINCT elastic_pool_name, ', ')
    FROM sys.database_service_objectives
    WHERE elastic_pool_name IS NOT NULL;
END
ELSE
BEGIN
    SET @PoolList = 'N/A (On-premises)';
END

-- Determine score and finding
IF @ServerName IS NOT NULL AND @DbList IS NOT NULL
BEGIN
    SET @Score = 2;
    SET @Finding = 'Inventory gathered: Instance=[' + @ServerName + ']; Databases=[' + ISNULL(@DbList, 'None') + ']; ElasticPools=[' + ISNULL(@PoolList, 'None') + ']. NOTE: This script provides automated evidence. Full compliance requires human review.';
END
ELSE IF @ServerName IS NOT NULL
BEGIN
    SET @Score = 1;
    SET @Finding = 'Partial inventory: Instance=[' + @ServerName + ']. Database enumeration failed.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'Failed to gather topology inventory.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;