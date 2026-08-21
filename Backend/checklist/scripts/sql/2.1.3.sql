SET NOCOUNT ON;

DECLARE @EngineEdition   INT           = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result          NVARCHAR(50);
DECLARE @Score           INT;
DECLARE @DatabaseQueried NVARCHAR(256) = N'SERVER';
DECLARE @Finding         NVARCHAR(4000);
DECLARE @Sql             NVARCHAR(MAX);
DECLARE @JobStepCount    INT = 0;
DECLARE @SsisProjects    INT = 0;
DECLARE @AccessNote      NVARCHAR(512) = N'';

IF OBJECT_ID(N'tempdb..#EtlSteps') IS NOT NULL DROP TABLE #EtlSteps;
CREATE TABLE #EtlSteps
(
    StepLabel NVARCHAR(512) NOT NULL,
    Command   NVARCHAR(MAX) NULL
);

IF OBJECT_ID(N'tempdb..#Issues') IS NOT NULL DROP TABLE #Issues;
CREATE TABLE #Issues
(
    ArtifactType NVARCHAR(50)  NOT NULL,
    ArtifactName NVARCHAR(512) NOT NULL,
    IssueType    NVARCHAR(80)  NOT NULL,
    Severity     INT           NOT NULL
);

/* ---------- SQL Agent ETL job steps (not present on Azure SQL Database) ---------- */
IF @EngineEdition <> 5 AND DB_ID(N'msdb') IS NOT NULL
BEGIN
    IF HAS_DBACCESS(N'msdb') = 1
    BEGIN
        BEGIN TRY
            INSERT INTO #EtlSteps (StepLabel, Command)
            SELECT j.name + N' :: ' + s.step_name, s.command
            FROM msdb.dbo.sysjobs AS j
            INNER JOIN msdb.dbo.sysjobsteps AS s
                ON s.job_id = j.job_id
            WHERE s.command IS NOT NULL
              AND (
                    s.subsystem IN (N'SSIS', N'CmdExec', N'PowerShell')
                 OR s.command COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%dtexec%'
                 OR s.command COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%bulk insert%'
                 OR s.command COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%openrowset%'
                 OR s.command COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%opendatasource%'
                 OR s.command COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%bcp %'
                 OR j.name    COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%etl%'
                 OR j.name    COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%load%'
                 OR j.name    COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%import%'
                 OR j.name    COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%extract%'
                 OR j.name    COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%staging%'
                  );

            SET @JobStepCount = (SELECT COUNT(*) FROM #EtlSteps);

            INSERT INTO #Issues (ArtifactType, ArtifactName, IssueType, Severity)
            SELECT DISTINCT
                   N'SQL Agent Job Step',
                   e.StepLabel,
                   p.IssueType,
                   p.Severity
            FROM #EtlSteps AS e
            CROSS APPLY (VALUES
                (N'%password=%',                          N'Hardcoded credential',        3),
                (N'%pwd=%',                               N'Hardcoded credential',        3),
                (N'%user id=%',                           N'Hardcoded credential',        3),
                (N'%uid=%',                               N'Hardcoded credential',        3),
                (N'%data source=%',                       N'Hardcoded server/connection', 2),
                (N'%initial catalog=%',                   N'Hardcoded server/connection', 2),
                (N'%opendatasource(%',                    N'Hardcoded server/connection', 2),
                (N'%[a-z]:\%',                            N'Hardcoded file path',         1),
                (N'%\\%',                                 N'Hardcoded file path',         1),
                (N'%20[0-9][0-9]-[0-1][0-9]-[0-3][0-9]%', N'Hardcoded date literal',      1)
            ) AS p(Pattern, IssueType, Severity)
            WHERE e.Command COLLATE SQL_Latin1_General_CP1_CI_AS LIKE p.Pattern;
        END TRY
        BEGIN CATCH
            SET @AccessNote = @AccessNote + N'msdb job metadata could not be read (' + ERROR_MESSAGE() + N'). ';
        END CATCH;
    END
    ELSE
        SET @AccessNote = @AccessNote + N'No access to msdb; SQL Agent ETL job steps were not inspected. ';
END;

/* ---------- SSIS catalog projects and parameters ---------- */
IF @EngineEdition <> 5 AND DB_ID(N'SSISDB') IS NOT NULL
BEGIN
    IF HAS_DBACCESS(N'SSISDB') = 1
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT @cnt = COUNT(*) FROM SSISDB.catalog.projects;';
            EXEC sys.sp_executesql @Sql, N'@cnt INT OUTPUT', @cnt = @SsisProjects OUTPUT;

            SET @Sql = N'
                SELECT N''SSIS Project'',
                       f.name + N''/'' + p.name,
                       N''Project has no environment reference (configuration not externalised)'',
                       2
                FROM SSISDB.catalog.projects AS p
                INNER JOIN SSISDB.catalog.folders AS f
                    ON f.folder_id = p.folder_id
                WHERE NOT EXISTS (SELECT 1
                                  FROM SSISDB.catalog.environment_references AS r
                                  WHERE r.project_id = p.project_id);';
            INSERT INTO #Issues (ArtifactType, ArtifactName, IssueType, Severity)
            EXEC sys.sp_executesql @Sql;

            SET @Sql = N'
                SELECT DISTINCT
                       N''SSIS Parameter'',
                       f.name + N''/'' + p.name + N'' :: '' + op.parameter_name,
                       x.IssueType,
                       x.Severity
                FROM SSISDB.catalog.object_parameters AS op
                INNER JOIN SSISDB.catalog.projects AS p
                    ON p.project_id = op.project_id
                INNER JOIN SSISDB.catalog.folders AS f
                    ON f.folder_id = p.folder_id
                CROSS APPLY (VALUES
                    (N''%password=%'',                          N''Credential in non-sensitive parameter default'', 3),
                    (N''%pwd=%'',                               N''Credential in non-sensitive parameter default'', 3),
                    (N''%data source=%'',                       N''Server/connection in parameter default'',        2),
                    (N''%initial catalog=%'',                   N''Server/connection in parameter default'',        2),
                    (N''%[a-z]:\%'',                            N''File path in parameter default'',                1),
                    (N''%\\%'',                                 N''File path in parameter default'',                1),
                    (N''%20[0-9][0-9]-[0-1][0-9]-[0-3][0-9]%'', N''Date literal in parameter default'',             1)
                ) AS x(Pattern, IssueType, Severity)
                WHERE op.sensitive = 0
                  AND op.design_default_value IS NOT NULL
                  AND CAST(op.design_default_value AS NVARCHAR(4000)) COLLATE SQL_Latin1_General_CP1_CI_AS LIKE x.Pattern;';
            INSERT INTO #Issues (ArtifactType, ArtifactName, IssueType, Severity)
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            SET @AccessNote = @AccessNote + N'SSISDB catalog could not be read (' + ERROR_MESSAGE() + N'). ';
        END CATCH;
    END
    ELSE
        SET @AccessNote = @AccessNote + N'No access to SSISDB; SSIS projects and parameters were not inspected. ';
END;

IF @EngineEdition = 5
    SET @AccessNote = N'Azure SQL Database: SQL Agent (msdb) and the SSIS catalog (SSISDB) do not exist, so ETL is orchestrated externally (e.g. Azure Data Factory / Synapse pipelines) and cannot be inspected from the instance. ';

DECLARE @IssueCount    INT = (SELECT COUNT(*) FROM #Issues);
DECLARE @MaxSeverity   INT = (SELECT ISNULL(MAX(Severity), 0) FROM #Issues);
DECLARE @CredCount     INT = (SELECT COUNT(*) FROM #Issues WHERE Severity = 3);
DECLARE @ServerCount   INT = (SELECT COUNT(*) FROM #Issues WHERE Severity = 2);
DECLARE @LowCount      INT = (SELECT COUNT(*) FROM #Issues WHERE Severity = 1);
DECLARE @ArtifactTotal INT = @JobStepCount + @SsisProjects;

DECLARE @Details NVARCHAR(2000) = ISNULL(STUFF((
        SELECT TOP (10) N'; ' + i.ArtifactType + N' "' + i.ArtifactName + N'" -> ' + i.IssueType
        FROM #Issues AS i
        ORDER BY i.Severity DESC, i.ArtifactType, i.ArtifactName
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N''), N'');

IF @ArtifactTotal = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No ETL artifacts were discoverable on this instance: '
                 + CAST(@JobStepCount AS NVARCHAR(20)) + N' ETL-related SQL Agent job step(s) and '
                 + CAST(@SsisProjects AS NVARCHAR(20)) + N' SSIS catalog project(s) found. '
                 + N'ETL parameterisation could not be evidenced from SQL Server metadata and requires manual review of the external ETL platform. '
                 + @AccessNote;
END
ELSE IF @IssueCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'ETL is parameterised. Inspected ' + CAST(@JobStepCount AS NVARCHAR(20))
                 + N' ETL-related SQL Agent job step(s) and ' + CAST(@SsisProjects AS NVARCHAR(20))
                 + N' SSIS catalog project(s); no hardcoded credentials, connection strings/servers, absolute or UNC file paths, or literal dates were detected in command text or non-sensitive SSIS parameter defaults. '
                 + @AccessNote;
END
ELSE IF @MaxSeverity = 1
BEGIN
    SET @Score = 2;
    SET @Finding = N'ETL is largely parameterised but ' + CAST(@LowCount AS NVARCHAR(20))
                 + N' low-severity hardcoding instance(s) were detected (absolute/UNC file paths or literal dates) across '
                 + CAST(@ArtifactTotal AS NVARCHAR(20)) + N' ETL artifact(s). Examples: ' + @Details + N'. '
                 + @AccessNote;
END
ELSE IF @MaxSeverity = 2
BEGIN
    SET @Score = 1;
    SET @Finding = N'ETL contains hardcoded server/connection details, or SSIS projects with no environment reference: '
                 + CAST(@ServerCount AS NVARCHAR(20)) + N' connection/configuration issue(s) and '
                 + CAST(@LowCount AS NVARCHAR(20)) + N' path/date issue(s) across '
                 + CAST(@ArtifactTotal AS NVARCHAR(20)) + N' ETL artifact(s). Examples: ' + @Details + N'. '
                 + @AccessNote;
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'Hardcoded credentials were detected in ETL definitions: ' + CAST(@CredCount AS NVARCHAR(20))
                 + N' credential issue(s), ' + CAST(@ServerCount AS NVARCHAR(20)) + N' server/connection issue(s) and '
                 + CAST(@LowCount AS NVARCHAR(20)) + N' path/date issue(s) across '
                 + CAST(@ArtifactTotal AS NVARCHAR(20)) + N' ETL artifact(s). Examples: ' + @Details + N'. '
                 + @AccessNote;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    CAST(@Result AS NVARCHAR(50))                AS Result,
    CAST(@Score AS INT)                          AS Score,
    CAST(@DatabaseQueried AS NVARCHAR(256))      AS DatabaseQueried,
    CAST(LEFT(@Finding, 4000) AS NVARCHAR(4000)) AS Finding;

IF OBJECT_ID(N'tempdb..#EtlSteps') IS NOT NULL DROP TABLE #EtlSteps;
IF OBJECT_ID(N'tempdb..#Issues') IS NOT NULL DROP TABLE #Issues;