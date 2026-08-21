-- Checklist: Elastic pools used where multiple databases share capacity efficiently
-- Scope: DATABASE
-- Scoring: 3: Database is assigned to an elastic pool (Azure SQL) or platform does not support elastic pools. 0: Database is not in an elastic pool on Azure SQL.

DECLARE @Result NVARCHAR(10) = 'Pass';
DECLARE @Score INT = 3;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DatabaseQueried = DB_NAME();
    
    DECLARE @PoolName NVARCHAR(128);
    SELECT @PoolName = elastic_pool_name FROM sys.database_service_objectives;
    
    IF @PoolName IS NOT NULL
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Database is assigned to elastic pool: ' + @PoolName;
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'Database is not assigned to an elastic pool';
    END
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Elastic pools are not applicable
    SET @DatabaseQueried = ISNULL(
        (SELECT STRING_AGG(name, ', ') FROM sys.databases WHERE database_id > 4 AND state = 0),
        'No user databases found'
    );
    SET @Score = 3;
    SET @Finding = 'Not applicable (Elastic pools are an Azure SQL Database feature)';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;