SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #EtlSignals
(
    SignalName  NVARCHAR(60) NOT NULL,
    SignalCount INT          NOT NULL
);

DECLARE @Sql NVARCHAR(MAX);

/* Azure SQL Database (EngineEdition 5) has no msdb, no SQL Agent and no SSIS catalog, so the inventory is skipped there. */
IF @EngineEdition <> 5
BEGIN
    /* SQL Agent job-step inventory (msdb referenced dynamically so the batch also compiles where msdb is absent). */
    IF OBJECT_ID(N'msdb.dbo.sysjobsteps') IS NOT NULL
    BEGIN
        SET @Sql = N'
        INSERT INTO #EtlSignals (SignalName, SignalCount)
        SELECT N''AgentSsisSteps'', COUNT(*)
        FROM msdb.dbo.sysjobsteps AS st
        INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = N''SSIS'';

        INSERT INTO #EtlSignals (SignalName, SignalCount)
        SELECT N''AgentTsqlEtlSteps'', COUNT(*)
        FROM msdb.dbo.sysjobsteps AS st
        INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem = N''TSQL''
          AND (st.command LIKE N''%BULK INSERT%''
            OR st.command LIKE N''%OPENROWSET%''
            OR st.command LIKE N''%OPENQUERY%''
            OR st.command LIKE N''%MERGE %''
            OR st.command LIKE N''%INSERT INTO%'');

        INSERT INTO #EtlSignals (SignalName, SignalCount)
        SELECT N''AgentCmdEtlSteps'', COUNT(*)
        FROM msdb.dbo.sysjobsteps AS st
        INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem IN (N''CmdExec'', N''PowerShell'')
          AND (st.command LIKE N''%dtexec%''
            OR st.command LIKE N''%.dtsx%''
            OR st.command LIKE N''%bcp %''
            OR st.command LIKE N''%Invoke-Sqlcmd%''
            OR st.command LIKE N''%sqlcmd%''
            OR st.command LIKE N''%azcopy%'');

        INSERT INTO #EtlSignals (SignalName, SignalCount)
        SELECT N''ReplicationAgentSteps'', COUNT(*)
        FROM msdb.dbo.sysjobsteps AS st
        INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id
        WHERE j.enabled = 1
          AND st.subsystem IN (N''Distribution'', N''LogReader'', N''Snapshot'', N''Merge'', N''QueueReader'');

        INSERT INTO #EtlSignals (SignalName, SignalCount)
        SELECT N''LinkedServerEtlSteps'', COUNT(DISTINCT st.step_uid)
        FROM msdb.dbo.sysjobsteps AS st
        INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id
        INNER JOIN sys.servers AS srv
            ON srv.is_linked = 1
           AND st.command LIKE N''%'' + srv.name + N''%''
        WHERE j.enabled = 1;';

        EXEC sys.sp_executesql @Sql;
    END

    /* Legacy (package deployment model) SSIS packages stored in msdb, excluding the Data Collector system folder. */
    IF OBJECT_ID(N'msdb.dbo.sysssispackages') IS NOT NULL
    BEGIN
        SET @Sql = N'
        INSERT INTO #EtlSignals (SignalName, SignalCount)
        SELECT N''SsisLegacyPackages'', COUNT(*)
        FROM msdb.dbo.sysssispackages AS p
        WHERE p.folderid NOT IN
        (
            SELECT f.folderid
            FROM msdb.dbo.sysssispackagefolders AS f
            WHERE f.foldername = N''Data Collector''
        );';

        EXEC sys.sp_executesql @Sql;
    END

    /* SSISDB (project deployment model) packages. */
    IF OBJECT_ID(N'SSISDB.catalog.packages') IS NOT NULL
    BEGIN
        SET @Sql = N'
        INSERT INTO #EtlSignals (SignalName, SignalCount)
        SELECT N''SsisCatalogPackages'', COUNT(*)
        FROM ' + QUOTENAME(N'SSISDB') + N'.[catalog].[packages];';

        EXEC sys.sp_executesql @Sql;
    END

    /* Point-in-time evidence of external ETL/orchestration tools connected to this instance. */
    INSERT INTO #EtlSignals (SignalName, SignalCount)
    SELECT N'ExternalEtlSessions', COUNT(*)
    FROM sys.dm_exec_sessions AS s
    WHERE s.is_user_process = 1
      AND (s.program_name LIKE N'%Azure Data Factory%'
        OR s.program_name LIKE N'%Databricks%'
        OR s.program_name LIKE N'%Informatica%'
        OR s.program_name LIKE N'%Talend%'
        OR s.program_name LIKE N'%Fivetran%'
        OR s.program_name LIKE N'%Matillion%'
        OR s.program_name LIKE N'%Mashup%');

    INSERT INTO #EtlSignals (SignalName, SignalCount)
    SELECT N'SsisRuntimeSessions', COUNT(*)
    FROM sys.dm_exec_sessions AS s
    WHERE s.is_user_process = 1
      AND (s.program_name LIKE N'SSIS-%'
        OR s.program_name LIKE N'%DtsDebugHost%'
        OR s.program_name LIKE N'%Microsoft SQL Server Integration Services%');
END

DECLARE @AgentSsisSteps        INT = ISNULL((SELECT SignalCount FROM #EtlSignals WHERE SignalName = N'AgentSsisSteps'), 0);
DECLARE @AgentTsqlEtlSteps     INT = ISNULL((SELECT SignalCount FROM #EtlSignals WHERE SignalName = N'AgentTsqlEtlSteps'), 0);
DECLARE @AgentCmdEtlSteps      INT = ISNULL((SELECT SignalCount FROM #EtlSignals WHERE SignalName = N'AgentCmdEtlSteps'), 0);
DECLARE @ReplicationAgentSteps INT = ISNULL((SELECT SignalCount FROM #EtlSignals WHERE SignalName = N'ReplicationAgentSteps'), 0);
DECLARE @LinkedServerEtlSteps  INT = ISNULL((SELECT SignalCount FROM #EtlSignals WHERE SignalName = N'LinkedServerEtlSteps'), 0);
DECLARE @SsisLegacyPackages    INT = ISNULL((SELECT SignalCount FROM #EtlSignals WHERE SignalName = N'SsisLegacyPackages'), 0);
DECLARE @SsisCatalogPackages   INT = ISNULL((SELECT SignalCount FROM #EtlSignals WHERE SignalName = N'SsisCatalogPackages'), 0);
DECLARE @ExternalEtlSessions   INT = ISNULL((SELECT SignalCount FROM #EtlSignals WHERE SignalName = N'ExternalEtlSessions'), 0);
DECLARE @SsisRuntimeSessions   INT = ISNULL((SELECT SignalCount FROM #EtlSignals WHERE SignalName = N'SsisRuntimeSessions'), 0);

DECLARE @UsesSsis     INT = CASE WHEN @AgentSsisSteps > 0 OR @SsisLegacyPackages > 0 OR @SsisCatalogPackages > 0 OR @SsisRuntimeSessions > 0 THEN 1 ELSE 0 END;
DECLARE @UsesTsql     INT = CASE WHEN @AgentTsqlEtlSteps > 0 THEN 1 ELSE 0 END;
DECLARE @UsesCmd      INT = CASE WHEN @AgentCmdEtlSteps > 0 THEN 1 ELSE 0 END;
DECLARE @UsesRepl     INT = CASE WHEN @ReplicationAgentSteps > 0 THEN 1 ELSE 0 END;
DECLARE @UsesLinked   INT = CASE WHEN @LinkedServerEtlSteps > 0 THEN 1 ELSE 0 END;
DECLARE @UsesExternal INT = CASE WHEN @ExternalEtlSessions > 0 THEN 1 ELSE 0 END;
DECLARE @SsisSplit    INT = CASE WHEN @SsisLegacyPackages > 0 AND @SsisCatalogPackages > 0 THEN 1 ELSE 0 END;

DECLARE @MechanismCount     INT = @UsesSsis + @UsesTsql + @UsesCmd + @UsesRepl + @UsesLinked + @UsesExternal;
DECLARE @InconsistencyCount INT = @MechanismCount + @SsisSplit;

DECLARE @Mechanisms NVARCHAR(1000) =
    STUFF(
        CASE WHEN @UsesSsis     = 1 THEN N', SSIS'                                   ELSE N'' END +
        CASE WHEN @UsesTsql     = 1 THEN N', T-SQL Agent jobs'                       ELSE N'' END +
        CASE WHEN @UsesCmd      = 1 THEN N', CmdExec/PowerShell (bcp/dtexec/sqlcmd)' ELSE N'' END +
        CASE WHEN @UsesRepl     = 1 THEN N', Replication'                            ELSE N'' END +
        CASE WHEN @UsesLinked   = 1 THEN N', Linked-server job steps'                ELSE N'' END +
        CASE WHEN @UsesExternal = 1 THEN N', External ETL tool sessions'             ELSE N'' END,
        1, 2, N'');

DECLARE @Score INT;

IF @EngineEdition = 5
    SET @Score = 1;
ELSE IF @MechanismCount = 0
    SET @Score = 1;
ELSE IF @InconsistencyCount = 1
    SET @Score = 3;
ELSE IF @InconsistencyCount = 2
    SET @Score = 2;
ELSE IF @InconsistencyCount = 3
    SET @Score = 1;
ELSE
    SET @Score = 0;

DECLARE @Result NVARCHAR(50);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DECLARE @Finding NVARCHAR(4000) =
    CASE
        WHEN @EngineEdition = 5
            THEN N'Azure SQL Database: SQL Agent (msdb) and SSIS catalog metadata are not available on this engine edition, so server-side ETL tooling cannot be inventoried. ETL for this database is orchestrated externally (for example Azure Data Factory or an SSIS Integration Runtime). Review the external pipeline inventory manually to confirm a single, deliberate ETL toolset is in use.'
        WHEN @MechanismCount = 0
            THEN N'No server-side ETL mechanism was detected: no enabled SQL Agent SSIS / T-SQL data-movement / CmdExec ETL job steps, no replication agents, no SSIS packages in msdb or SSISDB, and no external ETL tool sessions connected. Either ETL is performed entirely outside this instance (for example Azure Data Factory) or the ETL jobs are disabled - confirm the intended ETL toolset manually.'
        ELSE
            N'Distinct ETL mechanisms in active use: ' + CAST(@MechanismCount AS NVARCHAR(10)) + N' (' + @Mechanisms + N').'
            + CASE WHEN @SsisSplit = 1
                   THEN N' SSIS packages are split across BOTH deployment models (SSISDB catalog and legacy msdb storage), counted as an additional inconsistency.'
                   ELSE N'' END
            + N' Evidence: SSISDB catalog packages=' + CAST(@SsisCatalogPackages AS NVARCHAR(10))
            + N'; legacy msdb SSIS packages=' + CAST(@SsisLegacyPackages AS NVARCHAR(10))
            + N'; enabled Agent SSIS steps=' + CAST(@AgentSsisSteps AS NVARCHAR(10))
            + N'; enabled Agent T-SQL data-movement steps=' + CAST(@AgentTsqlEtlSteps AS NVARCHAR(10))
            + N'; enabled Agent CmdExec/PowerShell ETL steps=' + CAST(@AgentCmdEtlSteps AS NVARCHAR(10))
            + N'; replication agent steps=' + CAST(@ReplicationAgentSteps AS NVARCHAR(10))
            + N'; job steps referencing linked servers=' + CAST(@LinkedServerEtlSteps AS NVARCHAR(10))
            + N'; external ETL tool sessions=' + CAST(@ExternalEtlSessions AS NVARCHAR(10))
            + N'; SSIS runtime sessions=' + CAST(@SsisRuntimeSessions AS NVARCHAR(10))
            + N'. External/session-based signals are point-in-time only.'
    END;

SELECT
    CAST(@Result AS NVARCHAR(50))                           AS Result,
    CAST(@Score AS INT)                                     AS Score,
    CAST(N'msdb, SSISDB (instance-level)' AS NVARCHAR(256))  AS DatabaseQueried,
    CAST(@Finding AS NVARCHAR(4000))                        AS Finding;

DROP TABLE #EtlSignals;