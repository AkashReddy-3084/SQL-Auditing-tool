-- Checklist: ETL tooling is consistent and deliberate (SSIS / Azure Data Factory / T-SQL / other)
-- Scope: SERVER
-- Scoring: 3 = exactly one server-side ETL mechanism is in use and SSIS is not split across deployment models; 2 = two mechanisms, or one mechanism with SSIS split across both deployment models, or Azure SQL Database where ETL is orchestrated outside the engine; 1 = three mechanisms, or no server-side ETL tooling could be detected; 0 = four or more competing ETL mechanisms are in use

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'ETL tooling inventory could not be collected';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @SsisSteps INT = 0;
DECLARE @ReplSteps INT = 0;
DECLARE @CmdSteps INT = 0;
DECLARE @TsqlSteps INT = 0;
DECLARE @SsisMsdbPackages INT = 0;
DECLARE @SsisCatalogPackages INT = 0;
DECLARE @SsisSessions INT = 0;
DECLARE @ExternalSessions INT = 0;
DECLARE @Mechanisms INT = 0;
DECLARE @SsisSplit INT = 0;
DECLARE @Names NVARCHAR(400) = '';

DECLARE @Etl TABLE (SignalName NVARCHAR(60) NOT NULL, SignalCount INT NOT NULL);

-- SQL Agent (msdb) and the SSIS catalog do not exist on Azure SQL Database, so those
-- probes are issued through read-only dynamic SQL only on SQL Server and Managed Instance.
IF @Edition <> 5
BEGIN
    BEGIN TRY
        IF OBJECT_ID('msdb.dbo.sysjobsteps') IS NOT NULL
        BEGIN
            SET @Sql = N'
SELECT ''SsisSteps'', COUNT(*) FROM msdb.dbo.sysjobsteps AS st JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id WHERE j.enabled = 1 AND st.subsystem = ''SSIS''
UNION ALL
SELECT ''ReplSteps'', COUNT(*) FROM msdb.dbo.sysjobsteps AS st JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id WHERE j.enabled = 1 AND st.subsystem IN (''Distribution'', ''LogReader'', ''Snapshot'', ''QueueReader'')
UNION ALL
SELECT ''CmdSteps'', COUNT(*) FROM msdb.dbo.sysjobsteps AS st JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id WHERE j.enabled = 1 AND st.subsystem IN (''CmdExec'', ''PowerShell'')
UNION ALL
SELECT ''TsqlSteps'', COUNT(*) FROM msdb.dbo.sysjobsteps AS st JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id LEFT JOIN msdb.dbo.syscategories AS c ON c.category_id = j.category_id WHERE j.enabled = 1 AND st.subsystem = ''TSQL'' AND ISNULL(c.name, ''none'') NOT IN (''Database Maintenance'', ''Log Shipping'');';

            INSERT INTO @Etl (SignalName, SignalCount)
            EXEC sys.sp_executesql @Sql;
        END

        IF OBJECT_ID('msdb.dbo.sysssispackages') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT ''SsisMsdbPackages'', COUNT(*) FROM msdb.dbo.sysssispackages;';

            INSERT INTO @Etl (SignalName, SignalCount)
            EXEC sys.sp_executesql @Sql;
        END

        IF OBJECT_ID('SSISDB.catalog.packages') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT ''SsisCatalogPackages'', COUNT(*) FROM SSISDB.[catalog].[packages];';

            INSERT INTO @Etl (SignalName, SignalCount)
            EXEC sys.sp_executesql @Sql;
        END
    END TRY
    BEGIN CATCH
        SET @Finding = 'ETL tooling inventory was partially blocked: ' + ERROR_MESSAGE();
    END CATCH;
END

BEGIN TRY
    INSERT INTO @Etl (SignalName, SignalCount)
    SELECT 'SsisSessions', COUNT(*)
    FROM sys.dm_exec_sessions
    WHERE is_user_process = 1
      AND (program_name LIKE 'SSIS-%' OR program_name LIKE '%Integration Services%');

    INSERT INTO @Etl (SignalName, SignalCount)
    SELECT 'ExternalSessions', COUNT(*)
    FROM sys.dm_exec_sessions
    WHERE is_user_process = 1
      AND (program_name LIKE '%Azure Data Factory%' OR program_name LIKE '%Databricks%'
        OR program_name LIKE '%Informatica%' OR program_name LIKE '%Talend%'
        OR program_name LIKE '%Fivetran%' OR program_name LIKE '%Matillion%');
END TRY
BEGIN CATCH
    SET @ExternalSessions = 0;
END CATCH;

SELECT @SsisSteps = ISNULL(MAX(CASE WHEN SignalName = 'SsisSteps' THEN SignalCount END), 0),
       @ReplSteps = ISNULL(MAX(CASE WHEN SignalName = 'ReplSteps' THEN SignalCount END), 0),
       @CmdSteps = ISNULL(MAX(CASE WHEN SignalName = 'CmdSteps' THEN SignalCount END), 0),
       @TsqlSteps = ISNULL(MAX(CASE WHEN SignalName = 'TsqlSteps' THEN SignalCount END), 0),
       @SsisMsdbPackages = ISNULL(MAX(CASE WHEN SignalName = 'SsisMsdbPackages' THEN SignalCount END), 0),
       @SsisCatalogPackages = ISNULL(MAX(CASE WHEN SignalName = 'SsisCatalogPackages' THEN SignalCount END), 0),
       @SsisSessions = ISNULL(MAX(CASE WHEN SignalName = 'SsisSessions' THEN SignalCount END), 0),
       @ExternalSessions = ISNULL(MAX(CASE WHEN SignalName = 'ExternalSessions' THEN SignalCount END), 0)
FROM @Etl;

SET @SsisSplit = CASE WHEN @SsisMsdbPackages > 0 AND @SsisCatalogPackages > 0 THEN 1 ELSE 0 END;

SET @Names = ISNULL(STUFF(
      CASE WHEN @SsisSteps + @SsisMsdbPackages + @SsisCatalogPackages + @SsisSessions > 0 THEN ', SSIS' ELSE '' END
    + CASE WHEN @ReplSteps > 0 THEN ', Replication' ELSE '' END
    + CASE WHEN @CmdSteps > 0 THEN ', CmdExec/PowerShell command-line ETL' ELSE '' END
    + CASE WHEN @TsqlSteps > 0 THEN ', T-SQL Agent jobs' ELSE '' END
    + CASE WHEN @ExternalSessions > 0 THEN ', external ETL tool (ADF/Databricks/Informatica/Talend/Fivetran/Matillion)' ELSE '' END,
    1, 2, ''), 'none');

SET @Mechanisms =
      CASE WHEN @SsisSteps + @SsisMsdbPackages + @SsisCatalogPackages + @SsisSessions > 0 THEN 1 ELSE 0 END
    + CASE WHEN @ReplSteps > 0 THEN 1 ELSE 0 END
    + CASE WHEN @CmdSteps > 0 THEN 1 ELSE 0 END
    + CASE WHEN @TsqlSteps > 0 THEN 1 ELSE 0 END
    + CASE WHEN @ExternalSessions > 0 THEN 1 ELSE 0 END;

SET @Score = CASE
    WHEN @Edition = 5 THEN 2
    WHEN @Mechanisms = 0 THEN 1
    WHEN @Mechanisms = 1 AND @SsisSplit = 0 THEN 3
    WHEN @Mechanisms <= 2 THEN 2
    WHEN @Mechanisms = 3 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @Edition = 5
        THEN 'Azure SQL Database: SQL Agent (msdb) and the SSIS catalog are not available, so server-side ETL tooling cannot be inventoried; connected external ETL tool sessions = ' + CONVERT(NVARCHAR(20), @ExternalSessions)
    ELSE CONCAT(
        'distinct ETL mechanisms in use = ', @Mechanisms, ' (', @Names, ')',
        '; enabled Agent SSIS steps = ', @SsisSteps,
        '; replication agent steps = ', @ReplSteps,
        '; CmdExec/PowerShell steps = ', @CmdSteps,
        '; non-maintenance T-SQL steps = ', @TsqlSteps,
        '; SSISDB catalog packages = ', @SsisCatalogPackages,
        '; legacy msdb SSIS packages = ', @SsisMsdbPackages,
        '; SSIS runtime sessions = ', @SsisSessions,
        '; external ETL tool sessions = ', @ExternalSessions,
        CASE WHEN @SsisSplit = 1 THEN '; SSIS packages are split across both the SSISDB catalog and legacy msdb storage' ELSE '' END)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
