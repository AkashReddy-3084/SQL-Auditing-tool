/*
    Checklist 2.4.6 - Parallelism used appropriately (no unnecessary serial execution)
    Scope : SERVER (instance configuration + all accessible user databases)
    Mode  : READ-ONLY (system catalog views and DMVs only)
*/
SET NOCOUNT ON;

DECLARE @Result          nvarchar(20)  = N'Fail';
DECLARE @Score           int           = 3;
DECLARE @DatabaseQueried nvarchar(256) = N'master';
DECLARE @Finding         nvarchar(max) = N'';

DECLARE @EngineEdition   int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureDb       bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @MajorVersion    int = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));

SET @DatabaseQueried = CASE WHEN @IsAzureDb = 1 THEN DB_NAME() ELSE N'master' END;

DECLARE @ServerMaxDop    int = NULL;
DECLARE @CostThreshold   int = NULL;
DECLARE @CpuCount        int = NULL;
DECLARE @RgEnabled       int = 0;
DECLARE @RgSerialGroups  int = 0;

SELECT @CpuCount = cpu_count FROM sys.dm_os_sys_info;

/* ---------- Instance-level settings (not exposed on Azure SQL Database) ---------- */
IF @IsAzureDb = 0
BEGIN
    SELECT @ServerMaxDop  = CONVERT(int, c.value_in_use)
    FROM sys.configurations AS c
    WHERE c.name = N'max degree of parallelism';

    SELECT @CostThreshold = CONVERT(int, c.value_in_use)
    FROM sys.configurations AS c
    WHERE c.name = N'cost threshold for parallelism';

    /* Resource Governor views are absent on some editions - bind them late so the batch still compiles. */
    BEGIN TRY
        EXEC sp_executesql
             N'SELECT @e = CONVERT(int, rgc.is_enabled) FROM sys.resource_governor_configuration AS rgc;',
             N'@e int OUTPUT', @e = @RgEnabled OUTPUT;

        EXEC sp_executesql
             N'SELECT @c = COUNT(*) FROM sys.resource_governor_workload_groups AS wg WHERE wg.max_dop = 1;',
             N'@c int OUTPUT', @c = @RgSerialGroups OUTPUT;
    END TRY
    BEGIN CATCH
        SET @RgEnabled      = 0;
        SET @RgSerialGroups = 0;
    END CATCH
END

/* ---------- Per-database evidence ---------- */
DECLARE @DbScoped   TABLE (DatabaseName sysname NOT NULL, MaxDopValue int NULL);
DECLARE @ModuleHits TABLE (DatabaseName sysname NOT NULL, SerialModules int NOT NULL);

DECLARE @db      sysname;
DECLARE @prefix  nvarchar(300);
DECLARE @sql     nvarchar(max);
DECLARE @Scanned int = 0;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.state = 0
      AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb')
      AND (@IsAzureDb = 1 OR (d.database_id > 4 AND d.source_database_id IS NULL))
      AND HAS_DBACCESS(d.name) = 1
    ORDER BY d.name;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    /* Azure SQL Database forbids cross-database three-part names - stay in the current database there. */
    SET @prefix = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

    IF @MajorVersion IS NULL OR @MajorVersion >= 13
    BEGIN
        BEGIN TRY
            SET @sql = N'SELECT @dbn, CONVERT(int, dsc.value)
                         FROM ' + @prefix + N'sys.database_scoped_configurations AS dsc
                         WHERE dsc.name = N''MAXDOP'';';

            INSERT INTO @DbScoped (DatabaseName, MaxDopValue)
            EXEC sp_executesql @sql, N'@dbn sysname', @dbn = @db;
        END TRY
        BEGIN CATCH
            SET @sql = NULL;
        END CATCH
    END

    BEGIN TRY
        SET @sql = N'SELECT @dbn, COUNT(*)
                     FROM ' + @prefix + N'sys.sql_modules AS m
                     WHERE PATINDEX(N''%MAXDOP[ ]1%'', m.definition) > 0
                       AND PATINDEX(N''%MAXDOP[ ]1[0-9]%'', m.definition) = 0;';

        INSERT INTO @ModuleHits (DatabaseName, SerialModules)
        EXEC sp_executesql @sql, N'@dbn sysname', @dbn = @db;
    END TRY
    BEGIN CATCH
        SET @sql = NULL;
    END CATCH

    SET @Scanned = @Scanned + 1;
    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

/* ---------- Aggregate ---------- */
DECLARE @DbsSerialScoped int = (SELECT COUNT(*) FROM @DbScoped   WHERE MaxDopValue = 1);
DECLARE @ModulesSerial   int = (SELECT ISNULL(SUM(SerialModules), 0) FROM @ModuleHits);
DECLARE @DbsWithModules  int = (SELECT COUNT(*) FROM @ModuleHits WHERE SerialModules > 0);

DECLARE @SerialScopedList nvarchar(max) =
    STUFF((SELECT N', ' + s.DatabaseName
           FROM @DbScoped AS s
           WHERE s.MaxDopValue = 1
           ORDER BY s.DatabaseName
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

DECLARE @ModuleDbList nvarchar(max) =
    STUFF((SELECT N', ' + m.DatabaseName + N' (' + CONVERT(nvarchar(20), m.SerialModules) + N')'
           FROM @ModuleHits AS m
           WHERE m.SerialModules > 0
           ORDER BY m.SerialModules DESC, m.DatabaseName
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

DECLARE @RgSuppressing    bit = CASE WHEN @RgEnabled = 1 AND @RgSerialGroups > 0 THEN 1 ELSE 0 END;
DECLARE @UntunedThreshold bit = CASE WHEN @IsAzureDb = 0 AND ISNULL(@CostThreshold, 5) <= 5 THEN 1 ELSE 0 END;
DECLARE @UntunedMaxDop    bit = CASE WHEN @IsAzureDb = 0 AND @ServerMaxDop = 0 AND ISNULL(@CpuCount, 0) > 8 THEN 1 ELSE 0 END;

IF @IsAzureDb = 0 AND @ServerMaxDop = 1
    SET @Score = 0;
ELSE IF @IsAzureDb = 1 AND @DbsSerialScoped > 0
    SET @Score = 0;
ELSE IF @DbsSerialScoped > 0 OR @RgSuppressing = 1 OR @ModulesSerial > 5
    SET @Score = 1;
ELSE IF @ModulesSerial > 0 OR @UntunedThreshold = 1 OR @UntunedMaxDop = 1
    SET @Score = 2;
ELSE
    SET @Score = 3;

SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

/* ---------- Finding ---------- */
SET @Finding =
      N'Engine: ' + CASE WHEN @IsAzureDb = 1 THEN N'Azure SQL Database' ELSE N'SQL Server instance' END
    + N'. Logical CPUs: ' + ISNULL(CONVERT(nvarchar(20), @CpuCount), N'unknown')
    + N'. Instance MAXDOP: ' + CASE WHEN @IsAzureDb = 1 THEN N'n/a (not exposed)'
                                    ELSE ISNULL(CONVERT(nvarchar(20), @ServerMaxDop), N'unknown') END
    + N'. Cost threshold for parallelism: ' + CASE WHEN @IsAzureDb = 1 THEN N'n/a (not exposed)'
                                                   ELSE ISNULL(CONVERT(nvarchar(20), @CostThreshold), N'unknown') END
    + N'. Databases scanned: ' + CONVERT(nvarchar(20), @Scanned)
    + N'. Databases with scoped MAXDOP = 1: ' + CONVERT(nvarchar(20), @DbsSerialScoped)
    + ISNULL(N' [' + @SerialScopedList + N']', N'')
    + N'. Resource Governor: ' + CASE WHEN @IsAzureDb = 1 THEN N'n/a'
                                      WHEN @RgEnabled = 1 THEN N'enabled, ' + CONVERT(nvarchar(20), @RgSerialGroups) + N' workload group(s) with MAX_DOP = 1'
                                      ELSE N'disabled or unavailable' END
    + N'. T-SQL modules forcing OPTION (MAXDOP 1): ' + CONVERT(nvarchar(20), @ModulesSerial)
    + N' across ' + CONVERT(nvarchar(20), @DbsWithModules) + N' database(s)'
    + ISNULL(N' [' + @ModuleDbList + N']', N'')
    + N'. Assessment: '
    + CASE @Score
        WHEN 3 THEN N'Parallelism is enabled and tuned - no evidence of unnecessary serial execution.'
        WHEN 2 THEN N'Parallelism is permitted but not tuned'
                    + CASE WHEN @UntunedThreshold = 1 THEN N'; cost threshold for parallelism is still at or below the default of 5' ELSE N'' END
                    + CASE WHEN @UntunedMaxDop = 1 THEN N'; instance MAXDOP is 0 (unlimited) on a host with more than 8 logical processors' ELSE N'' END
                    + CASE WHEN @ModulesSerial > 0 THEN N'; ' + CONVERT(nvarchar(20), @ModulesSerial) + N' module(s) hard-code MAXDOP 1' ELSE N'' END
                    + N'.'
        WHEN 1 THEN N'Parallelism is materially suppressed'
                    + CASE WHEN @DbsSerialScoped > 0 THEN N'; database-scoped MAXDOP = 1 forces serial plans for entire databases' ELSE N'' END
                    + CASE WHEN @RgSuppressing = 1 THEN N'; an enabled Resource Governor workload group caps MAX_DOP at 1' ELSE N'' END
                    + CASE WHEN @ModulesSerial > 5 THEN N'; ' + CONVERT(nvarchar(20), @ModulesSerial) + N' module(s) hard-code MAXDOP 1' ELSE N'' END
                    + N'.'
        ELSE N'Parallelism is disabled outright (MAXDOP = 1) - every query, including ETL and data-integration loads, is forced to run serially.'
      END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;