/* ============================================================================
   Checklist 1.2.3 - Staging area is transient/isolated and not queried by consumers
   Scope  : DATABASE (runs in the context of each user database)
   Type   : READ-ONLY - catalog views and DMVs only, no data or schema changes
   Output : Result, Score, DatabaseQueried, Finding
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @DatabaseQueried sysname = DB_NAME();

/* ---------- 1. Staging schemas (standard naming conventions) ---------- */
DECLARE @StagingSchemas TABLE
(
    SchemaId   INT     NOT NULL PRIMARY KEY,
    SchemaName sysname NOT NULL
);

INSERT INTO @StagingSchemas (SchemaId, SchemaName)
SELECT s.schema_id, s.name
FROM sys.schemas AS s
WHERE s.name LIKE '%stag%'
   OR s.name LIKE 'stg%'
   OR s.name LIKE '%[_]stg'
   OR s.name LIKE '%land%'
   OR s.name LIKE '%raw%'
   OR s.name LIKE '%bronze%'
   OR s.name LIKE '%ingest%';

/* ---------- 2. Staging tables and views ---------- */
DECLARE @StagingObjects TABLE
(
    ObjectId   INT     NOT NULL PRIMARY KEY,
    SchemaId   INT     NOT NULL,
    SchemaName sysname NOT NULL,
    ObjectName sysname NOT NULL,
    ObjectType CHAR(2) NOT NULL
);

INSERT INTO @StagingObjects (ObjectId, SchemaId, SchemaName, ObjectName, ObjectType)
SELECT o.object_id, o.schema_id, s.name, o.name, o.type
FROM sys.objects AS o
INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('U', 'V')
  AND (
        o.schema_id IN (SELECT SchemaId FROM @StagingSchemas)
     OR o.name LIKE 'stg[_]%'
     OR o.name LIKE 'stage[_]%'
     OR o.name LIKE 'staging[_]%'
     OR o.name LIKE 'land[_]%'
     OR o.name LIKE '%[_]stg'
     OR o.name LIKE '%[_]staging'
      );

DECLARE @StagingObjectCount INT = (SELECT COUNT(*) FROM @StagingObjects);
DECLARE @StagingTableCount  INT = (SELECT COUNT(*) FROM @StagingObjects WHERE ObjectType = 'U');
DECLARE @StagingSchemaList  NVARCHAR(1000);

SELECT @StagingSchemaList = STUFF((
        SELECT TOP (5) N', ' + x.SchemaName
        FROM (SELECT DISTINCT so.SchemaName FROM @StagingObjects AS so) AS x
        ORDER BY x.SchemaName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N'');

/* ---------- 3. Consumer permission grants on the staging area ---------- */
DECLARE @ConsumerGrants INT = 0;
DECLARE @PublicGrants   INT = 0;
DECLARE @GrantList      NVARCHAR(1000);

SELECT
    @ConsumerGrants = COUNT(*),
    @PublicGrants   = SUM(CASE WHEN pr.name = 'public' THEN 1 ELSE 0 END)
FROM sys.database_permissions AS dp
INNER JOIN sys.database_principals AS pr ON pr.principal_id = dp.grantee_principal_id
WHERE dp.state IN ('G', 'W')
  AND dp.permission_name IN ('SELECT', 'EXECUTE', 'CONTROL', 'VIEW DEFINITION')
  AND (
        (dp.class = 1 AND dp.major_id IN (SELECT ObjectId FROM @StagingObjects))
     OR (dp.class = 3 AND dp.major_id IN (SELECT SchemaId FROM @StagingSchemas))
      )
  AND pr.name NOT IN ('dbo', 'db_owner', 'db_ddladmin', 'db_accessadmin',
                      'db_securityadmin', 'db_backupoperator')
  AND pr.name NOT LIKE '%etl%'
  AND pr.name NOT LIKE '%ssis%'
  AND pr.name NOT LIKE '%svc%'
  AND pr.name NOT LIKE '%loader%';

SELECT @GrantList = STUFF((
        SELECT TOP (5) N', ' + pr.name + N' (' + dp.permission_name + N')'
        FROM sys.database_permissions AS dp
        INNER JOIN sys.database_principals AS pr ON pr.principal_id = dp.grantee_principal_id
        WHERE dp.state IN ('G', 'W')
          AND dp.permission_name IN ('SELECT', 'EXECUTE', 'CONTROL', 'VIEW DEFINITION')
          AND (
                (dp.class = 1 AND dp.major_id IN (SELECT ObjectId FROM @StagingObjects))
             OR (dp.class = 3 AND dp.major_id IN (SELECT SchemaId FROM @StagingSchemas))
              )
          AND pr.name NOT IN ('dbo', 'db_owner', 'db_ddladmin', 'db_accessadmin',
                              'db_securityadmin', 'db_backupoperator')
          AND pr.name NOT LIKE '%etl%'
          AND pr.name NOT LIKE '%ssis%'
          AND pr.name NOT LIKE '%svc%'
          AND pr.name NOT LIKE '%loader%'
        ORDER BY pr.name
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N'');

/* ---------- 4. Consumer-facing objects reading from staging ---------- */
DECLARE @ConsumerObjectRefs INT = 0;
DECLARE @EtlProcedureRefs   INT = 0;
DECLARE @ConsumerRefList    NVARCHAR(1000);

SELECT
    @ConsumerObjectRefs = COUNT(DISTINCT CASE WHEN ro.type IN ('V', 'IF', 'TF', 'FN') THEN ro.object_id END),
    @EtlProcedureRefs   = COUNT(DISTINCT CASE WHEN ro.type = 'P' THEN ro.object_id END)
FROM sys.sql_expression_dependencies AS sed
INNER JOIN @StagingObjects AS so ON so.ObjectId = sed.referenced_id
INNER JOIN sys.objects AS ro ON ro.object_id = sed.referencing_id
WHERE sed.referenced_id IS NOT NULL
  AND ro.is_ms_shipped = 0
  AND ro.object_id NOT IN (SELECT ObjectId FROM @StagingObjects)
  AND ro.schema_id NOT IN (SELECT SchemaId FROM @StagingSchemas);

SELECT @ConsumerRefList = STUFF((
        SELECT TOP (5) N', ' + x.FullName
        FROM (
            SELECT DISTINCT rs.name + N'.' + ro.name AS FullName
            FROM sys.sql_expression_dependencies AS sed
            INNER JOIN @StagingObjects AS so ON so.ObjectId = sed.referenced_id
            INNER JOIN sys.objects AS ro ON ro.object_id = sed.referencing_id
            INNER JOIN sys.schemas AS rs ON rs.schema_id = ro.schema_id
            WHERE sed.referenced_id IS NOT NULL
              AND ro.is_ms_shipped = 0
              AND ro.type IN ('V', 'IF', 'TF', 'FN')
              AND ro.object_id NOT IN (SELECT ObjectId FROM @StagingObjects)
              AND ro.schema_id NOT IN (SELECT SchemaId FROM @StagingSchemas)
        ) AS x
        ORDER BY x.FullName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N'');

/* ---------- 5. Residency: are staging tables holding data right now? ---------- */
DECLARE @StagingTablesWithRows INT = 0;

SELECT @StagingTablesWithRows = COUNT(DISTINCT ps.object_id)
FROM sys.dm_db_partition_stats AS ps
INNER JOIN @StagingObjects AS so
        ON so.ObjectId = ps.object_id
       AND so.ObjectType = 'U'
WHERE ps.index_id IN (0, 1)
  AND ps.row_count > 0;

/* ---------- 6. Scoring ---------- */
DECLARE @Result  NVARCHAR(20);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(4000);

SET @ConsumerGrants     = ISNULL(@ConsumerGrants, 0);
SET @PublicGrants       = ISNULL(@PublicGrants, 0);
SET @ConsumerObjectRefs = ISNULL(@ConsumerObjectRefs, 0);
SET @EtlProcedureRefs   = ISNULL(@EtlProcedureRefs, 0);

IF @StagingObjectCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No staging schema or staging-named table/view was detected in database ['
                 + @DatabaseQueried
                 + N'] using standard naming conventions (stg/stage/staging/landing/raw/bronze/ingest). '
                 + N'Staging isolation and transience could therefore not be evidenced; either this database hosts no staging tier or the staging area uses a non-standard name that must be confirmed manually.';
END
ELSE IF @PublicGrants > 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'Staging area in database [' + @DatabaseQueried + N'] (schemas: '
                 + ISNULL(@StagingSchemaList, N'n/a') + N'; ' + CAST(@StagingObjectCount AS NVARCHAR(10))
                 + N' object(s)) is exposed to the public role: ' + CAST(@PublicGrants AS NVARCHAR(10))
                 + N' grant(s) to public out of ' + CAST(@ConsumerGrants AS NVARCHAR(10))
                 + N' non-ETL grant(s) [' + ISNULL(@GrantList, N'n/a') + N']. '
                 + CAST(@ConsumerObjectRefs AS NVARCHAR(10)) + N' consumer view/function(s) also read from staging ['
                 + ISNULL(@ConsumerRefList, N'none') + N']. '
                 + CAST(@StagingTablesWithRows AS NVARCHAR(10)) + N' of ' + CAST(@StagingTableCount AS NVARCHAR(10))
                 + N' staging table(s) currently hold rows.';
END
ELSE IF @ConsumerGrants > 0 OR @ConsumerObjectRefs > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Staging area in database [' + @DatabaseQueried + N'] (schemas: '
                 + ISNULL(@StagingSchemaList, N'n/a') + N'; ' + CAST(@StagingObjectCount AS NVARCHAR(10))
                 + N' object(s)) is not isolated from consumers: ' + CAST(@ConsumerGrants AS NVARCHAR(10))
                 + N' non-ETL principal grant(s) [' + ISNULL(@GrantList, N'none') + N'] and '
                 + CAST(@ConsumerObjectRefs AS NVARCHAR(10)) + N' consumer-facing view/function(s) reading staging ['
                 + ISNULL(@ConsumerRefList, N'none') + N']. ' + CAST(@EtlProcedureRefs AS NVARCHAR(10))
                 + N' stored procedure(s) reference staging (expected for ETL). '
                 + CAST(@StagingTablesWithRows AS NVARCHAR(10)) + N' of ' + CAST(@StagingTableCount AS NVARCHAR(10))
                 + N' staging table(s) currently hold rows.';
END
ELSE IF @StagingTablesWithRows > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Staging area in database [' + @DatabaseQueried + N'] (schemas: '
                 + ISNULL(@StagingSchemaList, N'n/a') + N'; ' + CAST(@StagingObjectCount AS NVARCHAR(10))
                 + N' object(s)) is isolated - no non-ETL principal holds permissions on it and no consumer view/function reads from it ('
                 + CAST(@EtlProcedureRefs AS NVARCHAR(10)) + N' ETL procedure reference(s) only). However '
                 + CAST(@StagingTablesWithRows AS NVARCHAR(10)) + N' of ' + CAST(@StagingTableCount AS NVARCHAR(10))
                 + N' staging table(s) hold resident rows at scan time, so transient load-and-clear behaviour is not confirmed.';
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = N'Staging area in database [' + @DatabaseQueried + N'] (schemas: '
                 + ISNULL(@StagingSchemaList, N'n/a') + N'; ' + CAST(@StagingObjectCount AS NVARCHAR(10))
                 + N' object(s)) is transient and isolated: all ' + CAST(@StagingTableCount AS NVARCHAR(10))
                 + N' staging table(s) are empty outside load windows, no non-ETL principal holds SELECT/EXECUTE/CONTROL/VIEW DEFINITION on the staging objects or schemas, and no consumer-facing view or function reads from staging ('
                 + CAST(@EtlProcedureRefs AS NVARCHAR(10)) + N' ETL procedure reference(s) only).';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

/* ---------- 7. Standard four-column result ---------- */
SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;