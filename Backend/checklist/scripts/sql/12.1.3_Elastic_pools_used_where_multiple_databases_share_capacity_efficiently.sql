-- Checklist: Elastic pools used where multiple databases share capacity efficiently
-- Scope: SERVER
-- Scoring: 0 = No elastic pool configured; 1 = Pool exists but only 1 DB assigned; 2 = Pool exists with 2-4 DBs; 3 = Pool exists with 5+ DBs sharing capacity efficiently
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @PoolDbCount INT = 0;

-- Azure SQL DB specific view; gracefully handles on-prem SQL Server
IF OBJECT_ID('sys.elastic_pool_members') IS NOT NULL
BEGIN
    SELECT @PoolDbCount = COUNT(*)
    FROM sys.elastic_pool_members;
END

IF @PoolDbCount = 0 SET @Score = 0;
ELSE IF @PoolDbCount = 1 SET @Score = 1;
ELSE IF @PoolDbCount BETWEEN 2 AND 4 SET @Score = 2;
ELSE SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;