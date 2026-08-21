/*==============================================================================
  Checklist Item : 1.1.2 - Environment separation exists (Dev / Test / Prod)
                   with isolated instances or databases
  Area           : Architecture & Design
  Scope          : SERVER
  Script Type    : T-SQL, strictly read-only (temp table only, no user-object DDL/DML)
  Output         : Result, Score, DatabaseQueried, Finding
  Method         : Classifies every user database on the instance into PROD /
                   NONPROD / UNKNOWN from its name tokens and reports whether the
                   instance is dedicated to a single environment tier.
==============================================================================*/
SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(20);
DECLARE @Score            INT;
DECLARE @Finding          NVARCHAR(4000);
DECLARE @DatabaseQueried  NVARCHAR(256) = COALESCE(CONVERT(NVARCHAR(256), SERVERPROPERTY('ServerName')), CONVERT(NVARCHAR(256), @@SERVERNAME));
DECLARE @InstanceName     NVARCHAR(128) = CONVERT(NVARCHAR(128), SERVERPROPERTY('InstanceName'));
DECLARE @EngineEdition    INT           = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @CurrentDb        NVARCHAR(128) = DB_NAME();
DECLARE @PlatformNote     NVARCHAR(400) = N'';
DECLARE @InstanceNote     NVARCHAR(400) = N'';

/* Azure SQL Database (EngineEdition 5): sys.databases lists every database only
   when the session is connected to master; from a user database the view is
   limited to master plus the current database. */
IF @EngineEdition = 5 AND ISNULL(@CurrentDb, N'') <> N'master'
    SET @PlatformNote = N' NOTE: Azure SQL Database detected and the session is connected to ['
                      + ISNULL(@CurrentDb, N'unknown')
                      + N'] rather than [master], so sys.databases visibility is limited to the current database; re-run against master for a full logical-server view.';
ELSE IF @EngineEdition = 5
    SET @PlatformNote = N' NOTE: Azure SQL Database detected; separation is assessed across the databases of the logical server.';

IF OBJECT_ID('tempdb..#EnvClassification') IS NOT NULL
    DROP TABLE #EnvClassification;

CREATE TABLE #EnvClassification
(
    DatabaseName SYSNAME     NOT NULL,
    EnvTag       VARCHAR(10) NOT NULL
);

INSERT INTO #EnvClassification (DatabaseName, EnvTag)
SELECT d.name,
       CASE
           WHEN LOWER(d.name) LIKE '%prod%'
             OR LOWER(d.name) LIKE '%[_ -]prd%'
             OR LOWER(d.name) LIKE '%prd[_ -]%'
             OR LOWER(d.name) LIKE '%live%'          THEN 'PROD'
           WHEN LOWER(d.name) LIKE '%dev%'
             OR LOWER(d.name) LIKE '%test%'
             OR LOWER(d.name) LIKE '%[_ -]tst%'
             OR LOWER(d.name) LIKE '%tst[_ -]%'
             OR LOWER(d.name) LIKE '%[_ -]qa%'
             OR LOWER(d.name) LIKE '%qa[_ -]%'
             OR LOWER(d.name) LIKE '%uat%'
             OR LOWER(d.name) LIKE '%stag%'
             OR LOWER(d.name) LIKE '%[_ -]stg%'
             OR LOWER(d.name) LIKE '%stg[_ -]%'
             OR LOWER(d.name) LIKE '%sandbox%'
             OR LOWER(d.name) LIKE '%demo%'
             OR LOWER(d.name) LIKE '%train%'         THEN 'NONPROD'
           ELSE 'UNKNOWN'
       END
FROM sys.databases AS d
WHERE d.database_id > 4
  AND d.name NOT IN (N'SSISDB', N'ReportServer', N'ReportServerTempDB', N'distribution');

DECLARE @Total        INT;
DECLARE @ProdCount    INT;
DECLARE @NonProdCount INT;
DECLARE @UnknownCount INT;
DECLARE @ProdList     NVARCHAR(MAX);
DECLARE @NonProdList  NVARCHAR(MAX);

SELECT @Total        = COUNT(*),
       @ProdCount    = SUM(CASE WHEN e.EnvTag = 'PROD'    THEN 1 ELSE 0 END),
       @NonProdCount = SUM(CASE WHEN e.EnvTag = 'NONPROD' THEN 1 ELSE 0 END),
       @UnknownCount = SUM(CASE WHEN e.EnvTag = 'UNKNOWN' THEN 1 ELSE 0 END)
FROM #EnvClassification AS e;

SET @Total        = ISNULL(@Total, 0);
SET @ProdCount    = ISNULL(@ProdCount, 0);
SET @NonProdCount = ISNULL(@NonProdCount, 0);
SET @UnknownCount = ISNULL(@UnknownCount, 0);

SELECT @ProdList = STUFF((SELECT N', ' + CONVERT(NVARCHAR(128), e.DatabaseName)
                          FROM #EnvClassification AS e
                          WHERE e.EnvTag = 'PROD'
                          ORDER BY e.DatabaseName
                          FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SELECT @NonProdList = STUFF((SELECT N', ' + CONVERT(NVARCHAR(128), e.DatabaseName)
                             FROM #EnvClassification AS e
                             WHERE e.EnvTag = 'NONPROD'
                             ORDER BY e.DatabaseName
                             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @ProdList    = LEFT(ISNULL(@ProdList, N'none'), 900);
SET @NonProdList = LEFT(ISNULL(@NonProdList, N'none'), 900);

IF @InstanceName IS NOT NULL
    SET @InstanceNote = N' Named instance: [' + @InstanceName + N'].';

IF @Total = 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'No user databases were found on instance [' + @DatabaseQueried
                 + N'], so environment separation cannot be demonstrated from instance metadata. Confirm that Dev, Test and Prod workloads run on isolated instances or isolated databases.'
                 + @InstanceNote + @PlatformNote;
END
ELSE IF @ProdCount > 0 AND @NonProdCount > 0
BEGIN
    SET @Score   = 0;
    SET @Finding = N'Instance [' + @DatabaseQueried + N'] hosts ' + CONVERT(NVARCHAR(10), @Total)
                 + N' user database(s) spanning MORE THAN ONE environment tier: '
                 + CONVERT(NVARCHAR(10), @ProdCount) + N' production-named (' + @ProdList + N') and '
                 + CONVERT(NVARCHAR(10), @NonProdCount) + N' non-production-named (' + @NonProdList
                 + N'), plus ' + CONVERT(NVARCHAR(10), @UnknownCount)
                 + N' unclassified. Production and non-production workloads are therefore NOT isolated at instance level.'
                 + @InstanceNote + @PlatformNote;
END
ELSE IF (@ProdCount > 0 OR @NonProdCount > 0) AND (@UnknownCount * 2) <= @Total
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Instance [' + @DatabaseQueried + N'] hosts ' + CONVERT(NVARCHAR(10), @Total)
                 + N' user database(s) that all resolve to a single environment tier ('
                 + CASE WHEN @ProdCount > 0 THEN N'PRODUCTION: ' + @ProdList
                        ELSE N'NON-PRODUCTION: ' + @NonProdList END
                 + N'); ' + CONVERT(NVARCHAR(10), @UnknownCount)
                 + N' database(s) carry no environment token. No mixing of production and non-production databases was detected, consistent with an instance dedicated to one environment.'
                 + @InstanceNote + @PlatformNote;
END
ELSE IF (@ProdCount > 0 OR @NonProdCount > 0)
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Instance [' + @DatabaseQueried + N'] shows a single environment tier with no mixing ('
                 + CASE WHEN @ProdCount > 0 THEN N'PRODUCTION: ' + @ProdList
                        ELSE N'NON-PRODUCTION: ' + @NonProdList END
                 + N'), but ' + CONVERT(NVARCHAR(10), @UnknownCount) + N' of ' + CONVERT(NVARCHAR(10), @Total)
                 + N' user database(s) carry no environment token, so the naming convention is applied inconsistently and separation is only weakly evidenced.'
                 + @InstanceNote + @PlatformNote;
END
ELSE
BEGIN
    SET @Score   = 1;
    SET @Finding = N'None of the ' + CONVERT(NVARCHAR(10), @Total)
                 + N' user database(s) on instance [' + @DatabaseQueried
                 + N'] carries a recognisable Dev/Test/QA/UAT/Staging/Prod naming token, so no environment separation convention is demonstrable from instance metadata.'
                 + @InstanceNote + @PlatformNote;
END

SET @Result  = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SET @Finding = LEFT(@Finding, 4000);

IF OBJECT_ID('tempdb..#EnvClassification') IS NOT NULL
    DROP TABLE #EnvClassification;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;