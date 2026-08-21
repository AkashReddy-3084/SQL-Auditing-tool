/* Checklist 14.5.3 - Parameter sniffing issues identified and mitigated (OPTIMIZE FOR, recompile, etc.)
   READ-ONLY. Aggregates parameter-sniffing mitigation artifacts across all accessible user databases. */
SET NOCOUNT ON;

DECLARE @EngineEdition INT;
DECLARE @MajorVersion INT;
DECLARE @TF4136 INT = 0;
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbsScanned INT = 0;
DECLARE @DbsWithModules INT = 0;
DECLARE @DbsMitigated INT = 0;
DECLARE @TotalModules INT = 0;
DECLARE @TotalMitigatedModules INT = 0;
DECLARE @TotalForcedPlans INT = 0;
DECLARE @TotalPlanGuides INT = 0;
DECLARE @DbsSniffingOff INT = 0;
DECLARE @DbsFailed INT = 0;
DECLARE @Score INT;
DECLARE @Result NVARCHAR(20);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @Base NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(4000);
DECLARE @ScanList NVARCHAR(MAX);
DECLARE @GapList NVARCHAR(MAX);

SET @EngineEdition = CAST(SERVERPROPERTY('EngineEdition') AS INT);
SET @MajorVersion = ISNULL(TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT), 0);
IF @EngineEdition IN (5, 8, 9, 11) AND @MajorVersion < 13
    SET @MajorVersion = 13;

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
IF OBJECT_ID('tempdb..#DbFindings') IS NOT NULL DROP TABLE #DbFindings;
IF OBJECT_ID('tempdb..#DbErrors') IS NOT NULL DROP TABLE #DbErrors;
IF OBJECT_ID('tempdb..#TraceStatus') IS NOT NULL DROP TABLE #TraceStatus;

CREATE TABLE #DbList (DatabaseName SYSNAME NOT NULL PRIMARY KEY);

CREATE TABLE #DbFindings (
    DatabaseName SYSNAME NOT NULL,
    ModuleCount INT NOT NULL,
    MitigatedModuleCount INT NOT NULL,
    SniffingDisabled INT NOT NULL,
    ForcedPlanCount INT NOT NULL,
    PlanGuideCount INT NOT NULL
);

CREATE TABLE #DbErrors (DatabaseName SYSNAME NOT NULL, ErrorMessage NVARCHAR(2048) NULL);

CREATE TABLE #TraceStatus (TraceFlag INT NULL, [Status] INT NULL, [Global] INT NULL, SessionScope INT NULL);

/* Instance-wide mitigation: trace flag 4136 disables parameter sniffing for the whole engine. */
BEGIN TRY
    IF @EngineEdition NOT IN (5, 6, 9, 11)
    BEGIN
        INSERT INTO #TraceStatus (TraceFlag, [Status], [Global], SessionScope)
        EXEC ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');
    END
END TRY
BEGIN CATCH
    DELETE FROM #TraceStatus;
END CATCH

SELECT @TF4136 = CASE WHEN EXISTS (SELECT 1 FROM #TraceStatus WHERE TraceFlag = 4136 AND [Status] = 1) THEN 1 ELSE 0 END;

/* Azure SQL Database cannot query sibling databases, so it inspects only the current one. */
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
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #DbList ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql =
            N'INSERT INTO #DbFindings (DatabaseName, ModuleCount, MitigatedModuleCount, SniffingDisabled, ForcedPlanCount, PlanGuideCount) SELECT @p_db, '
          + N'(SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o ON o.object_id = m.object_id WHERE o.is_ms_shipped = 0), '
          + N'(SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o ON o.object_id = m.object_id WHERE o.is_ms_shipped = 0 AND (m.is_recompiled = 1 OR m.definition LIKE N''%OPTIMIZE FOR%'' OR m.definition LIKE N''%RECOMPILE%'' OR m.definition LIKE N''%KEEPFIXED PLAN%'' OR m.definition LIKE N''%USE PLAN%'')), '
          + CASE WHEN @MajorVersion >= 13
                 THEN N'ISNULL((SELECT TOP (1) CASE WHEN TRY_CAST(c.value AS INT) = 0 THEN 1 ELSE 0 END FROM ' + QUOTENAME(@DbName) + N'.sys.database_scoped_configurations AS c WHERE c.name = N''PARAMETER_SNIFFING''), 0), '
                 ELSE N'0, ' END
          + CASE WHEN @MajorVersion >= 13
                 THEN N'ISNULL((SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.query_store_plan AS qp WHERE qp.is_forced_plan = 1), 0), '
                 ELSE N'0, ' END
          + N'ISNULL((SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.plan_guides AS g WHERE g.is_disabled = 0 AND (g.hints LIKE N''%OPTIMIZE FOR%'' OR g.hints LIKE N''%RECOMPILE%'' OR g.hints LIKE N''%USE PLAN%'')), 0);';

        EXEC sys.sp_executesql @Sql, N'@p_db SYSNAME', @p_db = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbErrors (DatabaseName, ErrorMessage) VALUES (@DbName, LEFT(ERROR_MESSAGE(), 2048));
    END CATCH

    FETCH NEXT FROM db_cur INTO @DbName;
END

CLOSE db_cur;
DEALLOCATE db_cur;

SELECT @DbsScanned            = COUNT(*),
       @DbsWithModules        = ISNULL(SUM(CASE WHEN f.ModuleCount > 0 THEN 1 ELSE 0 END), 0),
       @DbsMitigated          = ISNULL(SUM(CASE WHEN f.MitigatedModuleCount > 0 OR f.SniffingDisabled = 1 OR f.ForcedPlanCount > 0 OR f.PlanGuideCount > 0 THEN 1 ELSE 0 END), 0),
       @TotalModules          = ISNULL(SUM(f.ModuleCount), 0),
       @TotalMitigatedModules = ISNULL(SUM(f.MitigatedModuleCount), 0),
       @TotalForcedPlans      = ISNULL(SUM(f.ForcedPlanCount), 0),
       @TotalPlanGuides       = ISNULL(SUM(f.PlanGuideCount), 0),
       @DbsSniffingOff        = ISNULL(SUM(f.SniffingDisabled), 0)
FROM #DbFindings AS f;

SELECT @DbsFailed = COUNT(*) FROM #DbErrors;

SET @ScanList = STUFF((SELECT N', ' + f.DatabaseName
                       FROM #DbFindings AS f
                       ORDER BY f.DatabaseName
                       FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @GapList = STUFF((SELECT N', ' + f.DatabaseName
                      FROM #DbFindings AS f
                      WHERE f.ModuleCount > 0
                        AND f.MitigatedModuleCount = 0
                        AND f.SniffingDisabled = 0
                        AND f.ForcedPlanCount = 0
                        AND f.PlanGuideCount = 0
                      ORDER BY f.DatabaseName
                      FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @DatabaseQueried = CASE WHEN @ScanList IS NULL OR LEN(@ScanList) = 0 THEN N'None' ELSE LEFT(@ScanList, 3900) END;

SET @Base = N'Databases scanned: ' + CAST(@DbsScanned AS NVARCHAR(10))
          + N'; databases containing user T-SQL modules: ' + CAST(@DbsWithModules AS NVARCHAR(10))
          + N'; databases showing at least one parameter-sniffing mitigation: ' + CAST(@DbsMitigated AS NVARCHAR(10))
          + N'; modules using OPTIMIZE FOR / RECOMPILE / KEEPFIXED PLAN / USE PLAN: ' + CAST(@TotalMitigatedModules AS NVARCHAR(10)) + N' of ' + CAST(@TotalModules AS NVARCHAR(10))
          + N'; Query Store forced plans: ' + CAST(@TotalForcedPlans AS NVARCHAR(10))
          + N'; enabled plan guides with sniffing-related hints: ' + CAST(@TotalPlanGuides AS NVARCHAR(10))
          + N'; databases with PARAMETER_SNIFFING = OFF: ' + CAST(@DbsSniffingOff AS NVARCHAR(10))
          + N'; global trace flag 4136 enabled: ' + CASE WHEN @TF4136 = 1 THEN N'YES' ELSE N'NO' END
          + CASE WHEN @DbsFailed > 0 THEN N'; databases that could not be read: ' + CAST(@DbsFailed AS NVARCHAR(10)) ELSE N'' END
          + N'.';

IF @DbsScanned = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No accessible user database was found on this instance, so there is no user workload in which parameter sniffing could arise. ' + @Base;
END
ELSE IF @TF4136 = 1
BEGIN
    SET @Score = 3;
    SET @Finding = N'Global trace flag 4136 is enabled, applying an instance-wide parameter-sniffing mitigation to every database. ' + @Base;
END
ELSE IF @DbsWithModules = 0 AND @DbsMitigated = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No user-defined T-SQL modules exist in the scanned databases, so no cached parameterised module plans are exposed to sniffing. ' + @Base;
END
ELSE IF @DbsMitigated = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No parameter-sniffing mitigation was detected anywhere: no module uses OPTIMIZE FOR, RECOMPILE, KEEPFIXED PLAN or USE PLAN, no Query Store plan is forced, no enabled plan guide carries a sniffing-related hint, PARAMETER_SNIFFING is ON in every database and trace flag 4136 is off. ' + @Base + N' Databases with modules but no mitigation: ' + ISNULL(@GapList, N'(none)') + N'.';
END
ELSE IF (@DbsMitigated * 2) >= @DbsWithModules
BEGIN
    SET @Score = 3;
    SET @Finding = N'Parameter-sniffing mitigations are present in the majority of the databases that contain T-SQL modules. ' + @Base + CASE WHEN @GapList IS NOT NULL THEN N' Databases with modules but no mitigation: ' + @GapList + N'.' ELSE N'' END;
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = N'Parameter-sniffing mitigations are present in only a minority of the databases that contain T-SQL modules. ' + @Base + N' Databases with modules but no mitigation: ' + ISNULL(@GapList, N'(none)') + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = LEFT(@Finding, 3900);

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;