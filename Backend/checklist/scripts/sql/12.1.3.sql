-- Checklist: Elastic pools used where multiple databases share capacity efficiently
-- Scope: DATABASE
-- Scoring: 3 = in elastic pool; 2 = single database (production tier); 1 = single database (low tier); 0 = unable to determine

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    -- Azure SQL Database: Check current service objective
    -- Elastic pools are identified by 'ElasticPool' in the service_objective
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT 
        DB_NAME(),
        CASE 
            WHEN service_objective LIKE '%ElasticPool%' THEN 3
            WHEN service_objective LIKE 'GP%' OR service_objective LIKE 'BC%' OR service_objective LIKE 'P%' THEN 2
            WHEN service_objective LIKE 'S%' OR service_objective LIKE 'B%' THEN 1
            ELSE 0 
        END,
        'Service Objective: ' + service_objective
    FROM sys.database_service_objectives;
END
ELSE
BEGIN
    -- SQL Server / Managed Instance: Elastic pools are an Azure SQL DB feature.
    -- For MI/SQL Server, we report as not applicable/not used but score based on platform.
    -- Since they are not in elastic pools, we assign score 2 as they are typically production-grade instances.
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT 
        name, 
        2, 
        CASE 
            WHEN SERVERPROPERTY('EngineEdition') = 8 THEN 'Azure SQL Managed Instance: Resource sharing is handled at the instance level'
            ELSE 'SQL Server: Elastic pools are not applicable to this platform'
        END
    FROM sys.databases 
    WHERE database_id > 4 AND state = 0;
END

-- Aggregate results
SELECT @DatabaseQueried = ISNULL(STRING_AGG(DbName, ', '), 'None') FROM #DbResults;
SELECT @Score = ISNULL(MIN(DbScore), 0) FROM #DbResults;
SELECT @Finding = ISNULL(STRING_AGG(DbName + ': ' + Finding, '; '), 'No database found to be queried') FROM #DbResults;

-- Handle empty set
IF @DatabaseQueried = 'None'
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;