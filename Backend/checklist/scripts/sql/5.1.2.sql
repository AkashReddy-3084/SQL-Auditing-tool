/*
    Checklist Item : 5.1.2 - DQ rules codified (config-driven or reusable procedures), not ad-hoc manual checks
    Scope          : DATABASE (iterates every accessible user database, reports a single instance verdict)
    Access         : READ-ONLY - catalog views only, no data or schema modification
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#DbList')   IS NOT NULL DROP TABLE #DbList;
IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;

CREATE TABLE #DbList
(
    DatabaseName sysname NOT NULL
);

CREATE TABLE #Findings
(
    DatabaseName     sysname        NOT NULL,
    RuleConfigTables int            NULL,
    RuleProcedures   int            NULL,
    RuleFunctions    int            NULL,
    DqSchemaObjects  int            NULL,
    CheckConstraints int            NULL,
    Collected        bit            NOT NULL,
    ErrorText        nvarchar(2000) NULL,
    DbScore          int            NULL
);

DECLARE @Result          varchar(20)   = 'Fail';
DECLARE @Score           int           = 0;
DECLARE @DatabaseQueried nvarchar(max) = N'None';
DECLARE @Finding         nvarchar(max) = N'No database found to be queried';

DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));

-- EngineEdition 5 = Azure SQL Database: cross-database catalog access is not available.
IF @EngineEdition = 5
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.source_database_id IS NULL
      AND d.state_desc = 'ONLINE'
      AND d.is_read_only = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @TablePredicate  nvarchar(max);
DECLARE @ModulePredicate nvarchar(max);
DECLARE @DqSchemaList    nvarchar(400);

SET @DqSchemaList = N'''dq'',''dqm'',''dqf'',''dataquality'',''data_quality'',''quality'',''validation''';

SET @TablePredicate = N'
       (s.name IN (' + @DqSchemaList + N')
            AND (t.name LIKE ''%rule%'' OR t.name LIKE ''%config%'' OR t.name LIKE ''%definition%'' OR t.name LIKE ''%threshold%''))
    OR t.name LIKE ''%dq%rule%''
    OR t.name LIKE ''%dqrule%''
    OR t.name LIKE ''%dataquality%rule%''
    OR t.name LIKE ''%data[_]quality%rule%''
    OR t.name LIKE ''%quality[_]rule%''
    OR t.name LIKE ''%qualityrule%''
    OR t.name LIKE ''%validation[_]rule%''
    OR t.name LIKE ''%validationrule%''
    OR t.name LIKE ''%rule[_]definition%''
    OR t.name LIKE ''%ruledefinition%''
    OR t.name LIKE ''%rule[_]config%''
    OR t.name LIKE ''%ruleconfig%''
    OR t.name LIKE ''%rule[_]master%''
    OR t.name LIKE ''%dq[_]config%''
    OR t.name LIKE ''%dq[_]check%''
    OR t.name LIKE ''%quality[_]threshold%''';

SET @ModulePredicate = N'
       s.name IN (' + @DqSchemaList + N')
    OR o.name LIKE ''%dataquality%''
    OR o.name LIKE ''%data[_]quality%''
    OR o.name LIKE ''dq[_]%''
    OR o.name LIKE ''%[_]dq[_]%''
    OR o.name LIKE ''%dqrule%''
    OR o.name LIKE ''%dqcheck%''
    OR o.name LIKE ''%quality%check%''
    OR o.name LIKE ''%check%quality%''
    OR o.name LIKE ''%validate%''
    OR o.name LIKE ''%validation%''
    OR o.name LIKE ''%rule%engine%''
    OR o.name LIKE ''%run%rule%''
    OR o.name LIKE ''%apply%rule%''
    OR o.name LIKE ''%exec%rule%''
    OR o.name LIKE ''%rule%exec%''
    OR o.name LIKE ''%data[_]check%''
    OR o.name LIKE ''%datacheck%''
    OR o.name LIKE ''%reconcil%''
    OR o.name LIKE ''%completeness%''
    OR o.name LIKE ''%anomaly%''';

DECLARE @Db           sysname;
DECLARE @QDb          nvarchar(258);
DECLARE @Sql          nvarchar(max);
DECLARE @RuleTables   int;
DECLARE @RuleProcs    int;
DECLARE @RuleFuncs    int;
DECLARE @DqSchemaObjs int;
DECLARE @Checks       int;
DECLARE @ErrText      nvarchar(2000);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
    SELECT DatabaseName FROM #DbList ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @QDb          = QUOTENAME(@Db);
    SET @RuleTables   = NULL;
    SET @RuleProcs    = NULL;
    SET @RuleFuncs    = NULL;
    SET @DqSchemaObjs = NULL;
    SET @Checks       = NULL;
    SET @ErrText      = NULL;

    BEGIN TRY
        SET @Sql = N'
            SET @pRuleTables = (SELECT COUNT(*)
                                FROM ' + @QDb + N'.sys.tables AS t
                                INNER JOIN ' + @QDb + N'.sys.schemas AS s ON s.schema_id = t.schema_id
                                WHERE t.is_ms_shipped = 0 AND (' + @TablePredicate + N'));

            SET @pRuleProcs  = (SELECT COUNT(*)
                                FROM ' + @QDb + N'.sys.procedures AS o
                                INNER JOIN ' + @QDb + N'.sys.schemas AS s ON s.schema_id = o.schema_id
                                WHERE o.is_ms_shipped = 0 AND (' + @ModulePredicate + N'));

            SET @pRuleFuncs  = (SELECT COUNT(*)
                                FROM ' + @QDb + N'.sys.objects AS o
                                INNER JOIN ' + @QDb + N'.sys.schemas AS s ON s.schema_id = o.schema_id
                                WHERE o.is_ms_shipped = 0
                                  AND o.type IN (''FN'',''IF'',''TF'')
                                  AND (' + @ModulePredicate + N'));

            SET @pDqSchema   = (SELECT COUNT(*)
                                FROM ' + @QDb + N'.sys.objects AS o
                                INNER JOIN ' + @QDb + N'.sys.schemas AS s ON s.schema_id = o.schema_id
                                WHERE o.is_ms_shipped = 0
                                  AND s.name IN (' + @DqSchemaList + N'));

            SET @pChecks     = (SELECT COUNT(*)
                                FROM ' + @QDb + N'.sys.check_constraints AS cc
                                WHERE cc.is_disabled = 0);';

        EXEC sys.sp_executesql
             @Sql,
             N'@pRuleTables int OUTPUT, @pRuleProcs int OUTPUT, @pRuleFuncs int OUTPUT, @pDqSchema int OUTPUT, @pChecks int OUTPUT',
             @pRuleTables = @RuleTables   OUTPUT,
             @pRuleProcs  = @RuleProcs    OUTPUT,
             @pRuleFuncs  = @RuleFuncs    OUTPUT,
             @pDqSchema   = @DqSchemaObjs OUTPUT,
             @pChecks     = @Checks       OUTPUT;

        INSERT INTO #Findings (DatabaseName, RuleConfigTables, RuleProcedures, RuleFunctions, DqSchemaObjects, CheckConstraints, Collected, ErrorText, DbScore)
        SELECT @Db, ISNULL(@RuleTables, 0), ISNULL(@RuleProcs, 0), ISNULL(@RuleFuncs, 0), ISNULL(@DqSchemaObjs, 0), ISNULL(@Checks, 0), 1, NULL,
               CASE
                   WHEN ISNULL(@RuleTables, 0) >= 1 AND (ISNULL(@RuleProcs, 0) + ISNULL(@RuleFuncs, 0)) >= 1 THEN 3
                   WHEN (ISNULL(@RuleProcs, 0) + ISNULL(@RuleFuncs, 0)) >= 1 THEN 2
                   WHEN ISNULL(@DqSchemaObjs, 0) >= 1 OR ISNULL(@Checks, 0) >= 1 THEN 1
                   ELSE 0
               END;
    END TRY
    BEGIN CATCH
        SET @ErrText = LEFT(ERROR_MESSAGE(), 2000);

        INSERT INTO #Findings (DatabaseName, RuleConfigTables, RuleProcedures, RuleFunctions, DqSchemaObjects, CheckConstraints, Collected, ErrorText, DbScore)
        VALUES (@Db, NULL, NULL, NULL, NULL, NULL, 0, @ErrText, 0);
    END CATCH

    FETCH NEXT FROM db_cursor INTO @Db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

IF NOT EXISTS (SELECT 1 FROM #Findings)
BEGIN
    SET @Score           = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
END
ELSE
BEGIN
    DECLARE @TotalDbs        int;
    DECLARE @ConfigDriven    int;
    DECLARE @RoutinesOnly    int;
    DECLARE @ConstraintsOnly int;
    DECLARE @NoArtifacts     int;
    DECLARE @Unreadable      int;
    DECLARE @ListConfig      nvarchar(max);
    DECLARE @ListRoutines    nvarchar(max);
    DECLARE @ListConstraints nvarchar(max);
    DECLARE @ListNone        nvarchar(max);
    DECLARE @ListError       nvarchar(max);

    SELECT
        @TotalDbs        = COUNT(*),
        @ConfigDriven    = SUM(CASE WHEN f.Collected = 1 AND f.DbScore = 3 THEN 1 ELSE 0 END),
        @RoutinesOnly    = SUM(CASE WHEN f.Collected = 1 AND f.DbScore = 2 THEN 1 ELSE 0 END),
        @ConstraintsOnly = SUM(CASE WHEN f.Collected = 1 AND f.DbScore = 1 THEN 1 ELSE 0 END),
        @NoArtifacts     = SUM(CASE WHEN f.Collected = 1 AND f.DbScore = 0 THEN 1 ELSE 0 END),
        @Unreadable      = SUM(CASE WHEN f.Collected = 0 THEN 1 ELSE 0 END),
        @Score           = MIN(f.DbScore)
    FROM #Findings AS f;

    SET @DatabaseQueried = STUFF((SELECT N', ' + f.DatabaseName
                                  FROM #Findings AS f
                                  ORDER BY f.DatabaseName
                                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @ListConfig = STUFF((SELECT N', ' + f.DatabaseName
                             FROM #Findings AS f
                             WHERE f.Collected = 1 AND f.DbScore = 3
                             ORDER BY f.DatabaseName
                             FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @ListRoutines = STUFF((SELECT N', ' + f.DatabaseName
                               FROM #Findings AS f
                               WHERE f.Collected = 1 AND f.DbScore = 2
                               ORDER BY f.DatabaseName
                               FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @ListConstraints = STUFF((SELECT N', ' + f.DatabaseName
                                  FROM #Findings AS f
                                  WHERE f.Collected = 1 AND f.DbScore = 1
                                  ORDER BY f.DatabaseName
                                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @ListNone = STUFF((SELECT N', ' + f.DatabaseName
                           FROM #Findings AS f
                           WHERE f.Collected = 1 AND f.DbScore = 0
                           ORDER BY f.DatabaseName
                           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @ListError = STUFF((SELECT N', ' + f.DatabaseName
                            FROM #Findings AS f
                            WHERE f.Collected = 0
                            ORDER BY f.DatabaseName
                            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @Finding =
          N'Databases examined: ' + CONVERT(nvarchar(10), @TotalDbs)
        + N'. Config-driven DQ rules (rule configuration table plus reusable procedure/function): ' + CONVERT(nvarchar(10), @ConfigDriven)
        + CASE WHEN @ListConfig IS NULL THEN N'' ELSE N' [' + LEFT(@ListConfig, 600) + N']' END
        + N'. Reusable DQ routines but no rule configuration store: ' + CONVERT(nvarchar(10), @RoutinesOnly)
        + CASE WHEN @ListRoutines IS NULL THEN N'' ELSE N' [' + LEFT(@ListRoutines, 600) + N']' END
        + N'. Declarative constraints or isolated DQ objects only: ' + CONVERT(nvarchar(10), @ConstraintsOnly)
        + CASE WHEN @ListConstraints IS NULL THEN N'' ELSE N' [' + LEFT(@ListConstraints, 600) + N']' END
        + N'. No DQ codification artifacts: ' + CONVERT(nvarchar(10), @NoArtifacts)
        + CASE WHEN @ListNone IS NULL THEN N'' ELSE N' [' + LEFT(@ListNone, 600) + N']' END
        + N'. Metadata unreadable: ' + CONVERT(nvarchar(10), @Unreadable)
        + CASE WHEN @ListError IS NULL THEN N'' ELSE N' [' + LEFT(@ListError, 600) + N']' END
        + N'. '
        + CASE @Score
              WHEN 3 THEN N'Every database examined stores DQ rule definitions in configuration tables and executes them through reusable procedures/functions.'
              WHEN 2 THEN N'Reusable DQ routines exist, but at least one database has no rule configuration store, so rule definitions are hard-coded rather than config-driven.'
              WHEN 1 THEN N'At least one database relies only on declarative constraints or isolated DQ objects, with no reusable DQ routine or rule configuration store.'
              ELSE N'At least one database has no DQ rule configuration tables and no reusable DQ procedures/functions, indicating ad-hoc manual data quality checking.'
          END;
END

SET @Result = CASE WHEN @Score = 3 THEN 'Pass' ELSE 'Fail' END;
SET @DatabaseQueried = LEFT(@DatabaseQueried, 4000);
SET @Finding = LEFT(@Finding, 4000);

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;