SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSqlDb BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
CREATE TABLE #Dbs (DatabaseName SYSNAME NOT NULL PRIMARY KEY);

IF OBJECT_ID('tempdb..#EtlModules') IS NOT NULL DROP TABLE #EtlModules;
CREATE TABLE #EtlModules
(
    DatabaseName    SYSNAME       NOT NULL,
    SchemaName      SYSNAME       NOT NULL,
    ObjectName      SYSNAME       NOT NULL,
    ObjectType      NVARCHAR(60)  NOT NULL,
    HasTryCatch     BIT           NOT NULL,
    HasErrorHandler BIT           NOT NULL
);

IF OBJECT_ID('tempdb..#EtlJobSteps') IS NOT NULL DROP TABLE #EtlJobSteps;
CREATE TABLE #EtlJobSteps
(
    JobName       SYSNAME       NOT NULL,
    StepName      SYSNAME       NOT NULL,
    Subsystem     NVARCHAR(60)  NULL,
    OnFailAction  INT           NULL,
    RetryAttempts INT           NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #Dbs (DatabaseName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.is_in_standby = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db SYSNAME;
DECLARE @prefix NVARCHAR(300);
DECLARE @sql NVARCHAR(MAX);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Dbs ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

        SET @sql = N'
        SELECT
            @dbn,
            s.name,
            o.name,
            o.type_desc,
            CASE WHEN UPPER(m.definition) LIKE ''%BEGIN TRY%''
                  AND UPPER(m.definition) LIKE ''%BEGIN CATCH%'' THEN 1 ELSE 0 END,
            CASE WHEN UPPER(m.definition) LIKE ''%ERROR_MESSAGE%''
                   OR UPPER(m.definition) LIKE ''%RAISERROR%''
                   OR UPPER(m.definition) LIKE ''%THROW%''
                   OR UPPER(m.definition) LIKE ''%XACT_STATE%'' THEN 1 ELSE 0 END
        FROM ' + @prefix + N'sys.sql_modules AS m
        INNER JOIN ' + @prefix + N'sys.objects AS o ON o.object_id = m.object_id
        INNER JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0
          AND o.type IN (''P'', ''TR'')
          AND (
                   LOWER(o.name) LIKE ''%etl%''
                OR LOWER(o.name) LIKE ''%load%''
                OR LOWER(o.name) LIKE ''%import%''
                OR LOWER(o.name) LIKE ''%export%''
                OR LOWER(o.name) LIKE ''%extract%''
                OR LOWER(o.name) LIKE ''%staging%''
                OR LOWER(o.name) LIKE ''%stg[_]%''
                OR LOWER(o.name) LIKE ''%transform%''
                OR LOWER(o.name) LIKE ''%ingest%''
                OR LOWER(o.name) LIKE ''%merge%''
                OR LOWER(o.name) LIKE ''%sync%''
                OR LOWER(s.name) LIKE ''%etl%''
                OR LOWER(s.name) LIKE ''%stg%''
                OR LOWER(s.name) LIKE ''%staging%''
                OR UPPER(m.definition) LIKE ''%BULK INSERT%''
                OR UPPER(m.definition) LIKE ''%OPENROWSET%''
                OR UPPER(m.definition) LIKE ''%MERGE %''
              );';

        INSERT INTO #EtlModules (DatabaseName, SchemaName, ObjectName, ObjectType, HasTryCatch, HasErrorHandler)
        EXEC sp_executesql @sql, N'@dbn SYSNAME', @dbn = @db;
    END TRY
    BEGIN CATCH
        SET @sql = NULL;
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

IF @IsAzureSqlDb = 0 AND DB_ID('msdb') IS NOT NULL
BEGIN
    BEGIN TRY
        SET @sql = N'
        SELECT
            j.name,
            st.step_name,
            st.subsystem,
            st.on_fail_action,
            st.retry_attempts
        FROM msdb.dbo.sysjobs AS j
        INNER JOIN msdb.dbo.sysjobsteps AS st ON st.job_id = j.job_id
        WHERE j.enabled = 1
          AND (
                   st.subsystem IN (''SSIS'', ''DTS'')
                OR LOWER(j.name) LIKE ''%etl%''
                OR LOWER(j.name) LIKE ''%load%''
                OR LOWER(j.name) LIKE ''%import%''
                OR LOWER(j.name) LIKE ''%extract%''
                OR LOWER(j.name) LIKE ''%staging%''
                OR LOWER(st.step_name) LIKE ''%etl%''
                OR LOWER(st.step_name) LIKE ''%load%''
                OR LOWER(st.step_name) LIKE ''%import%''
              );';

        INSERT INTO #EtlJobSteps (JobName, StepName, Subsystem, OnFailAction, RetryAttempts)
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @sql = NULL;
    END CATCH
END

DECLARE @TotalModules INT = (SELECT COUNT(*) FROM #EtlModules);
DECLARE @ModulesOk    INT = (SELECT COUNT(*) FROM #EtlModules WHERE HasTryCatch = 1);
DECLARE @TotalSteps   INT = (SELECT COUNT(*) FROM #EtlJobSteps);
DECLARE @StepsOk      INT = (SELECT COUNT(*) FROM #EtlJobSteps WHERE OnFailAction = 4 OR RetryAttempts > 0);
DECLARE @SsisSteps    INT = (SELECT COUNT(*) FROM #EtlJobSteps WHERE Subsystem IN ('SSIS', 'DTS'));

DECLARE @TotalUnits INT = @TotalModules + @TotalSteps;
DECLARE @UnitsOk    INT = @ModulesOk + @StepsOk;
DECLARE @Coverage DECIMAL(6,2) =
    CASE WHEN @TotalUnits = 0 THEN 0 ELSE (@UnitsOk * 100.0) / @TotalUnits END;

DECLARE @BadModules NVARCHAR(1500) = ISNULL(STUFF((
        SELECT TOP (5) N'; ' + e.DatabaseName + N'.' + e.SchemaName + N'.' + e.ObjectName
        FROM #EtlModules AS e
        WHERE e.HasTryCatch = 0
        ORDER BY e.DatabaseName, e.SchemaName, e.ObjectName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @BadSteps NVARCHAR(1500) = ISNULL(STUFF((
        SELECT TOP (5) N'; ' + s.JobName + N' / ' + s.StepName
        FROM #EtlJobSteps AS s
        WHERE NOT (s.OnFailAction = 4 OR s.RetryAttempts > 0)
        ORDER BY s.JobName, s.StepName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @DbCount INT = (SELECT COUNT(*) FROM #Dbs);
DECLARE @DbList NVARCHAR(MAX) = ISNULL(STUFF((
        SELECT N', ' + d.DatabaseName
        FROM #Dbs AS d
        ORDER BY d.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @DatabaseQueried NVARCHAR(1000) =
    CASE
        WHEN @DbCount = 0 THEN N'No accessible user databases'
        WHEN @DbCount <= 10 THEN LEFT(@DbList, 900)
        ELSE CAST(@DbCount AS NVARCHAR(10)) + N' accessible user databases'
    END
    + CASE WHEN @IsAzureSqlDb = 0 THEN N' + msdb' ELSE N'' END;

DECLARE @Score INT;
DECLARE @Result NVARCHAR(20);

IF @TotalUnits = 0
BEGIN
    SET @Score = 0;
    SET @Result = N'NeedsReview';
END
ELSE
BEGIN
    IF @Coverage >= 90 SET @Score = 3;
    ELSE IF @Coverage >= 70 SET @Score = 2;
    ELSE IF @Coverage >= 30 SET @Score = 1;
    ELSE SET @Score = 0;

    IF @SsisSteps > 0 AND @Score = 3 SET @Score = 2;

    SET @Result = CASE WHEN @Score = 3 THEN N'Pass'
                       WHEN @Score = 2 THEN N'NeedsReview'
                       ELSE N'Fail' END;
END

DECLARE @Finding NVARCHAR(4000) =
    CASE
        WHEN @TotalUnits = 0 THEN
            N'No ETL-related T-SQL modules or ETL/SSIS SQL Agent job steps were discovered across '
            + @DatabaseQueried
            + N'. Structured ETL error handling could not be evidenced from SQL Server metadata; ETL may run entirely on an external platform (ADF, Databricks, third-party tool) and requires manual review.'
        ELSE
            N'ETL error-handling coverage ' + CAST(@Coverage AS NVARCHAR(10)) + N'% ('
            + CAST(@UnitsOk AS NVARCHAR(10)) + N' of ' + CAST(@TotalUnits AS NVARCHAR(10))
            + N' ETL units compliant). T-SQL ETL modules: ' + CAST(@ModulesOk AS NVARCHAR(10))
            + N' of ' + CAST(@TotalModules AS NVARCHAR(10)) + N' contain BEGIN TRY/BEGIN CATCH. '
            + N'ETL job steps: ' + CAST(@StepsOk AS NVARCHAR(10)) + N' of ' + CAST(@TotalSteps AS NVARCHAR(10))
            + N' define an explicit on-failure path (goto step) or retry attempts; '
            + CAST(@SsisSteps AS NVARCHAR(10)) + N' are SSIS/DTS steps whose package-internal event handlers are not visible to SQL Server metadata'
            + CASE WHEN @SsisSteps > 0 THEN N' (score capped pending manual package review)' ELSE N'' END
            + N'. Modules without TRY/CATCH (up to 5): ' + @BadModules
            + N'. Job steps without a failure path (up to 5): ' + @BadSteps + N'.'
    END;

IF OBJECT_ID('tempdb..#EtlModules') IS NOT NULL DROP TABLE #EtlModules;
IF OBJECT_ID('tempdb..#EtlJobSteps') IS NOT NULL DROP TABLE #EtlJobSteps;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;

SELECT
    @Result           AS Result,
    @Score            AS Score,
    @DatabaseQueried  AS DatabaseQueried,
    @Finding          AS Finding;