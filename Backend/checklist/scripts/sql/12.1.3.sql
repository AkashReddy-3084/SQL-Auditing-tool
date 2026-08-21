SET NOCOUNT ON;

DECLARE @EngineEdition   INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DbContext       SYSNAME        = DB_NAME();
DECLARE @Result          NVARCHAR(30);
DECLARE @Score           INT            = 0;
DECLARE @Finding         NVARCHAR(4000) = N'';

IF OBJECT_ID('tempdb..#PoolInfo') IS NOT NULL
    DROP TABLE #PoolInfo;

CREATE TABLE #PoolInfo
(
    DatabaseName     SYSNAME NOT NULL,
    ElasticPoolName  SYSNAME NULL,
    ServiceObjective SYSNAME NULL
);

/* sys.database_service_objectives exists only on Azure SQL Database, so it is referenced through dynamic SQL. */
IF @EngineEdition = 5 AND OBJECT_ID('sys.database_service_objectives') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
        INSERT INTO #PoolInfo (DatabaseName, ElasticPoolName, ServiceObjective)
        SELECT d.name,
               dso.elastic_pool_name,
               dso.service_objective
        FROM sys.databases AS d
        LEFT JOIN sys.database_service_objectives AS dso
               ON dso.database_id = d.database_id
        WHERE d.name <> N''master'';';
END

DECLARE @TotalDb   INT = (SELECT COUNT(*) FROM #PoolInfo);
DECLARE @PooledDb  INT = (SELECT COUNT(*) FROM #PoolInfo WHERE ElasticPoolName IS NOT NULL);
DECLARE @PoolCount INT = (SELECT COUNT(DISTINCT ElasticPoolName) FROM #PoolInfo WHERE ElasticPoolName IS NOT NULL);

DECLARE @PoolList NVARCHAR(2000) = N'';
SELECT @PoolList = @PoolList
                 + CASE WHEN @PoolList = N'' THEN N'' ELSE N', ' END
                 + p.ElasticPoolName
FROM (SELECT DISTINCT ElasticPoolName FROM #PoolInfo WHERE ElasticPoolName IS NOT NULL) AS p;

DECLARE @UnpooledList NVARCHAR(2000) = N'';
SELECT @UnpooledList = @UnpooledList
                     + CASE WHEN @UnpooledList = N'' THEN N'' ELSE N', ' END
                     + u.DatabaseName
FROM (SELECT TOP (20) DatabaseName
      FROM #PoolInfo
      WHERE ElasticPoolName IS NULL
      ORDER BY DatabaseName) AS u;

IF @EngineEdition <> 5
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Elastic pools are an Azure SQL Database feature. SERVERPROPERTY(''EngineEdition'') returned '
                 + CAST(@EngineEdition AS NVARCHAR(10))
                 + N' ('
                 + CASE @EngineEdition
                       WHEN 1  THEN N'Personal/Desktop'
                       WHEN 2  THEN N'Standard'
                       WHEN 3  THEN N'Enterprise'
                       WHEN 4  THEN N'Express'
                       WHEN 6  THEN N'Azure Synapse Analytics'
                       WHEN 8  THEN N'Azure SQL Managed Instance'
                       WHEN 9  THEN N'Azure SQL Edge'
                       WHEN 11 THEN N'Azure Synapse serverless SQL pool'
                       ELSE N'other'
                   END
                 + N'), which does not expose elastic pools, so the control is not applicable to this platform. Confirm manually whether shared capacity is instead handled by instance consolidation or licence pooling.';
END
ELSE IF @DbContext <> N'master'
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Connected to Azure SQL Database ''' + @DbContext
                 + N''' rather than the logical server''s master database, so sys.databases and sys.database_service_objectives expose only the current database and server-wide pool membership cannot be enumerated. Observed for this database: elastic pool = '
                 + ISNULL((SELECT TOP (1) ElasticPoolName FROM #PoolInfo WHERE DatabaseName = @DbContext), N'(none / not visible)')
                 + N'. Re-run the check against master for full coverage.';
END
ELSE IF @TotalDb = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'No user databases exist on this Azure SQL logical server (sys.databases returned only master), so there is no multi-database workload that would benefit from an elastic pool.';
END
ELSE IF @TotalDb = 1
BEGIN
    SET @Score   = 3;
    SET @Finding = N'The logical server hosts a single user database ('
                 + ISNULL((SELECT TOP (1) DatabaseName FROM #PoolInfo), N'unknown')
                 + N') with service objective '
                 + ISNULL((SELECT TOP (1) ServiceObjective FROM #PoolInfo), N'unknown')
                 + N' and elastic pool '
                 + ISNULL((SELECT TOP (1) ElasticPoolName FROM #PoolInfo), N'(none)')
                 + N'. Elastic pools share capacity across multiple databases and are not required for a single-database server.';
END
ELSE IF @PooledDb = @TotalDb
BEGIN
    SET @Score   = 3;
    SET @Finding = N'All ' + CAST(@TotalDb AS NVARCHAR(10))
                 + N' user databases on this logical server are members of an elastic pool ('
                 + CAST(@PoolCount AS NVARCHAR(10)) + N' pool(s): ' + @PoolList
                 + N'), so compute capacity is shared rather than provisioned per database.';
END
ELSE IF @PooledDb > 0
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Elastic pools are in use but coverage is partial: ' + CAST(@PooledDb AS NVARCHAR(10))
                 + N' of ' + CAST(@TotalDb AS NVARCHAR(10))
                 + N' user databases belong to a pool (' + CAST(@PoolCount AS NVARCHAR(10)) + N' pool(s): ' + @PoolList
                 + N'). Databases still provisioned as single databases include: ' + @UnpooledList
                 + N'. Review whether those were deliberately kept outside a pool for performance or isolation reasons.';
END
ELSE
BEGIN
    SET @Score   = 0;
    SET @Finding = N'This Azure SQL logical server hosts ' + CAST(@TotalDb AS NVARCHAR(10))
                 + N' user databases and none of them belong to an elastic pool - every database is provisioned as an isolated single database. Unpooled databases include: ' + @UnpooledList
                 + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result    AS Result,
       @Score     AS Score,
       @DbContext AS DatabaseQueried,
       @Finding   AS Finding;

IF OBJECT_ID('tempdb..#PoolInfo') IS NOT NULL
    DROP TABLE #PoolInfo;