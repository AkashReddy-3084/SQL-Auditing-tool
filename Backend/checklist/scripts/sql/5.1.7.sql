/* Checklist 5.1.7 - DQ failures halt progression where critical (bad data not silently promoted) */
/* Read-only. Inspects catalog metadata only; no user data is read and nothing is modified. */
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Pat') IS NOT NULL DROP TABLE #Pat;
IF OBJECT_ID('tempdb..#DQHalt') IS NOT NULL DROP TABLE #DQHalt;

CREATE TABLE #Pat
(
    Kind    varchar(10)   NOT NULL,
    Pattern nvarchar(200) NOT NULL
);

INSERT INTO #Pat (Kind, Pattern) VALUES
    ('DQ',    N'%data[_]quality%'),
    ('DQ',    N'%dataquality%'),
    ('DQ',    N'%data quality%'),
    ('DQ',    N'%dq[_]%'),
    ('DQ',    N'%[_]dq[_]%'),
    ('DQ',    N'dq'),
    ('DQ',    N'%dataqual%'),
    ('DQ',    N'%validation%'),
    ('DQ',    N'%quality%'),
    ('DQ',    N'%rule[_]result%'),
    ('DQ',    N'%dqresult%'),
    ('QUAR',  N'%quarantine%'),
    ('QUAR',  N'%reject%'),
    ('QUAR',  N'%exception%'),
    ('QUAR',  N'%dead[_]letter%'),
    ('QUAR',  N'%deadletter%'),
    ('QUAR',  N'%bad[_]record%'),
    ('QUAR',  N'%bad[_]row%'),
    ('QUAR',  N'%failed[_]row%'),
    ('QUAR',  N'%error[_]row%'),
    ('DQREF', N'%data[_]quality%'),
    ('DQREF', N'%dataquality%'),
    ('DQREF', N'%data quality%'),
    ('DQREF', N'%dq[_]%'),
    ('DQREF', N'%validate%'),
    ('DQREF', N'%validation%'),
    ('DQREF', N'%quality%check%'),
    ('DQREF', N'%quarantine%'),
    ('DQREF', N'%reject%'),
    ('HALT',  N'%throw%'),
    ('HALT',  N'%raiserror%'),
    ('HALT',  N'%rollback%'),
    ('HALT',  N'%sp[_]stop[_]job%');

CREATE TABLE #DQHalt
(
    DatabaseName      sysname        NOT NULL,
    DQArtifacts       int            NOT NULL,
    QuarantineObjects int            NOT NULL,
    DQModules         int            NOT NULL,
    HaltModules       int            NOT NULL,
    HaltSample        nvarchar(400)  NULL
);

DECLARE @IsAzureDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

DECLARE @Targets TABLE (DatabaseName sysname NOT NULL);

IF @IsAzureDb = 1
    INSERT INTO @Targets (DatabaseName) VALUES (DB_NAME());
ELSE
    INSERT INTO @Targets (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_read_only = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @Db      sysname,
        @Prefix  nvarchar(300),
        @Sql     nvarchar(max),
        @DQ      int,
        @Quar    int,
        @Mods    int,
        @Halt    int,
        @Sample  nvarchar(400);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM @Targets ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @DQ = 0; SET @Quar = 0; SET @Mods = 0; SET @Halt = 0; SET @Sample = NULL;
    SET @Prefix = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@Db) + N'.' END;

    BEGIN TRY
        SET @Sql = N'
        SELECT
            @pDQ = (SELECT COUNT(*)
                    FROM ' + @Prefix + N'sys.objects AS o
                    INNER JOIN ' + @Prefix + N'sys.schemas AS s ON s.schema_id = o.schema_id
                    WHERE o.type IN (''U'', ''V'')
                      AND o.is_ms_shipped = 0
                      AND EXISTS (SELECT 1 FROM #Pat AS p
                                  WHERE p.Kind = ''DQ''
                                    AND (o.name COLLATE Latin1_General_CI_AS LIKE p.Pattern COLLATE Latin1_General_CI_AS
                                      OR s.name COLLATE Latin1_General_CI_AS LIKE p.Pattern COLLATE Latin1_General_CI_AS))),
            @pQuar = (SELECT COUNT(*)
                      FROM ' + @Prefix + N'sys.objects AS o
                      WHERE o.type IN (''U'', ''V'')
                        AND o.is_ms_shipped = 0
                        AND EXISTS (SELECT 1 FROM #Pat AS p
                                    WHERE p.Kind = ''QUAR''
                                      AND o.name COLLATE Latin1_General_CI_AS LIKE p.Pattern COLLATE Latin1_General_CI_AS)),
            @pMods = (SELECT COUNT(*)
                      FROM ' + @Prefix + N'sys.sql_modules AS m
                      INNER JOIN ' + @Prefix + N'sys.objects AS o ON o.object_id = m.object_id
                      WHERE o.type IN (''P'', ''TR'')
                        AND o.is_ms_shipped = 0
                        AND EXISTS (SELECT 1 FROM #Pat AS p
                                    WHERE p.Kind = ''DQREF''
                                      AND m.definition COLLATE Latin1_General_CI_AS LIKE p.Pattern COLLATE Latin1_General_CI_AS)),
            @pHalt = (SELECT COUNT(*)
                      FROM ' + @Prefix + N'sys.sql_modules AS m
                      INNER JOIN ' + @Prefix + N'sys.objects AS o ON o.object_id = m.object_id
                      WHERE o.type IN (''P'', ''TR'')
                        AND o.is_ms_shipped = 0
                        AND EXISTS (SELECT 1 FROM #Pat AS p
                                    WHERE p.Kind = ''DQREF''
                                      AND m.definition COLLATE Latin1_General_CI_AS LIKE p.Pattern COLLATE Latin1_General_CI_AS)
                        AND EXISTS (SELECT 1 FROM #Pat AS p
                                    WHERE p.Kind = ''HALT''
                                      AND m.definition COLLATE Latin1_General_CI_AS LIKE p.Pattern COLLATE Latin1_General_CI_AS)),
            @pSample = (SELECT TOP (1) QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name)
                        FROM ' + @Prefix + N'sys.sql_modules AS m
                        INNER JOIN ' + @Prefix + N'sys.objects AS o ON o.object_id = m.object_id
                        INNER JOIN ' + @Prefix + N'sys.schemas AS s ON s.schema_id = o.schema_id
                        WHERE o.type IN (''P'', ''TR'')
                          AND o.is_ms_shipped = 0
                          AND EXISTS (SELECT 1 FROM #Pat AS p
                                      WHERE p.Kind = ''DQREF''
                                        AND m.definition COLLATE Latin1_General_CI_AS LIKE p.Pattern COLLATE Latin1_General_CI_AS)
                          AND EXISTS (SELECT 1 FROM #Pat AS p
                                      WHERE p.Kind = ''HALT''
                                        AND m.definition COLLATE Latin1_General_CI_AS LIKE p.Pattern COLLATE Latin1_General_CI_AS)
                        ORDER BY s.name, o.name);';

        EXEC sp_executesql
             @Sql,
             N'@pDQ int OUTPUT, @pQuar int OUTPUT, @pMods int OUTPUT, @pHalt int OUTPUT, @pSample nvarchar(400) OUTPUT',
             @pDQ = @DQ OUTPUT, @pQuar = @Quar OUTPUT, @pMods = @Mods OUTPUT, @pHalt = @Halt OUTPUT, @pSample = @Sample OUTPUT;

        INSERT INTO #DQHalt (DatabaseName, DQArtifacts, QuarantineObjects, DQModules, HaltModules, HaltSample)
        VALUES (@Db, ISNULL(@DQ, 0), ISNULL(@Quar, 0), ISNULL(@Mods, 0), ISNULL(@Halt, 0), @Sample);
    END TRY
    BEGIN CATCH
        /* Database not readable by this login - skip it rather than failing the whole audit */
        PRINT N'Skipped database ' + QUOTENAME(@Db) + N': ' + ERROR_MESSAGE();
    END CATCH

    FETCH NEXT FROM db_cur INTO @Db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @TotalDbs    int,
        @DbsWithDQ   int,
        @DbsWithHalt int,
        @DbsWithQuar int,
        @DbList      nvarchar(max),
        @Detail      nvarchar(max),
        @Result      nvarchar(20),
        @Score       int,
        @Finding     nvarchar(max);

SELECT @TotalDbs    = COUNT(*),
       @DbsWithDQ   = SUM(CASE WHEN DQArtifacts > 0 OR DQModules > 0 THEN 1 ELSE 0 END),
       @DbsWithHalt = SUM(CASE WHEN HaltModules > 0 THEN 1 ELSE 0 END),
       @DbsWithQuar = SUM(CASE WHEN QuarantineObjects > 0 THEN 1 ELSE 0 END)
FROM #DQHalt;

SET @TotalDbs    = ISNULL(@TotalDbs, 0);
SET @DbsWithDQ   = ISNULL(@DbsWithDQ, 0);
SET @DbsWithHalt = ISNULL(@DbsWithHalt, 0);
SET @DbsWithQuar = ISNULL(@DbsWithQuar, 0);

SELECT @DbList = STUFF((SELECT N', ' + DatabaseName
                        FROM #DQHalt
                        ORDER BY DatabaseName
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
IF @DbList IS NULL SET @DbList = N'N/A';

SELECT @Detail = STUFF((SELECT N'; ' + DatabaseName
                             + N' (DQ objects: ' + CAST(DQArtifacts AS nvarchar(10))
                             + N', DQ modules: ' + CAST(DQModules AS nvarchar(10))
                             + N', halting DQ modules: ' + CAST(HaltModules AS nvarchar(10))
                             + N', quarantine objects: ' + CAST(QuarantineObjects AS nvarchar(10))
                             + CASE WHEN HaltSample IS NOT NULL THEN N', e.g. ' + HaltSample ELSE N'' END
                             + N')'
                        FROM #DQHalt
                        WHERE DQArtifacts > 0 OR DQModules > 0 OR QuarantineObjects > 0
                        ORDER BY DatabaseName
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
IF @Detail IS NULL SET @Detail = N'none';

IF @TotalDbs = 0
BEGIN
    SET @Score  = 0;
    SET @Finding = N'No accessible user database could be inspected on this instance, so the presence of data quality gates that halt progression could not be determined. Grant read access to the relevant data platform databases and re-run.';
END
ELSE IF @DbsWithDQ = 0
BEGIN
    SET @Score  = 0;
    SET @Finding = N'No data quality or validation artifacts were found in any of the ' + CAST(@TotalDbs AS nvarchar(10))
                 + N' inspected database(s): no DQ/validation tables or views and no procedures or triggers referencing DQ/validation logic. There is no enforced gate, so records that fail quality expectations can be promoted downstream without detection.';
END
ELSE IF @DbsWithHalt = 0 AND @DbsWithQuar = 0
BEGIN
    SET @Score  = 0;
    SET @Finding = N'Data quality artifacts exist in ' + CAST(@DbsWithDQ AS nvarchar(10)) + N' of ' + CAST(@TotalDbs AS nvarchar(10))
                 + N' inspected database(s), but no DQ-referencing procedure or trigger contains halt logic (THROW, RAISERROR, ROLLBACK or sp_stop_job) and no quarantine/reject objects exist. DQ results appear to be recorded only, so failures do not stop progression. Detail: ' + @Detail + N'.';
END
ELSE IF @DbsWithHalt = 0
BEGIN
    SET @Score  = 1;
    SET @Finding = N'Data quality artifacts exist in ' + CAST(@DbsWithDQ AS nvarchar(10)) + N' of ' + CAST(@TotalDbs AS nvarchar(10))
                 + N' inspected database(s) and ' + CAST(@DbsWithQuar AS nvarchar(10))
                 + N' database(s) contain quarantine/reject objects, but no DQ-referencing procedure or trigger aborts execution via THROW, RAISERROR, ROLLBACK or sp_stop_job. Failing rows may be diverted, yet nothing observably blocks the run. Detail: ' + @Detail + N'.';
END
ELSE IF @DbsWithHalt < @DbsWithDQ
BEGIN
    SET @Score  = 2;
    SET @Finding = N'Halting data quality enforcement is inconsistent: ' + CAST(@DbsWithHalt AS nvarchar(10)) + N' of '
                 + CAST(@DbsWithDQ AS nvarchar(10)) + N' DQ-bearing database(s) contain DQ-referencing modules that abort on failure (THROW, RAISERROR, ROLLBACK or sp_stop_job), while the remainder record DQ outcomes without any observable stop. Detail: ' + @Detail + N'.';
END
ELSE
BEGIN
    SET @Score  = 3;
    SET @Finding = N'All ' + CAST(@DbsWithDQ AS nvarchar(10)) + N' DQ-bearing database(s) of ' + CAST(@TotalDbs AS nvarchar(10))
                 + N' inspected contain DQ-referencing procedures or triggers that abort execution on failure (THROW, RAISERROR, ROLLBACK or sp_stop_job), and ' + CAST(@DbsWithQuar AS nvarchar(10))
                 + N' database(s) also isolate failing rows in quarantine/reject objects, so critical DQ failures stop progression rather than silently promoting bad data. Detail: ' + @Detail + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DQHalt;
DROP TABLE #Pat;

SELECT @Result  AS Result,
       @Score   AS Score,
       @DbList  AS DatabaseQueried,
       @Finding AS Finding;