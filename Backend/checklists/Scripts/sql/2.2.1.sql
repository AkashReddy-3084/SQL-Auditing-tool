/*
    Checklist 2.2.1 - Incremental load implemented where applicable (watermark / CDC / Change Tracking)
    Read-only inventory of change-capture artifacts across every accessible user database.
*/
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Inc') IS NOT NULL
    DROP TABLE #Inc;
IF OBJECT_ID('tempdb..#Scored') IS NOT NULL
    DROP TABLE #Scored;

CREATE TABLE #Inc
(
    DatabaseName        sysname NOT NULL,
    UserTables          int     NOT NULL,
    CdcEnabled          bit     NOT NULL,
    CdcCaptureInstances int     NOT NULL,
    CtEnabled           bit     NOT NULL,
    CtTables            int     NOT NULL,
    TemporalTables      int     NOT NULL,
    WatermarkTables     int     NOT NULL,
    RowVersionColumns   int     NOT NULL,
    ChangeDateColumns   int     NOT NULL
);

DECLARE @IsAzureSqlDb     bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;
DECLARE @MajorVersion     int = TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), 4) AS int);
DECLARE @SupportsTemporal bit = CASE WHEN ISNULL(@MajorVersion, 0) >= 13 OR CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

DECLARE @Template nvarchar(max) = N'
INSERT INTO #Inc (DatabaseName, UserTables, CdcEnabled, CdcCaptureInstances, CtEnabled, CtTables,
                  TemporalTables, WatermarkTables, RowVersionColumns, ChangeDateColumns)
SELECT
    @DbName,
    (SELECT COUNT(*)
       FROM {P}sys.tables t
       INNER JOIN {P}sys.schemas s ON s.schema_id = t.schema_id
      WHERE t.is_ms_shipped = 0 AND s.name <> ''cdc''),
    @CdcOn,
    {CDC},
    @CtOn,
    (SELECT COUNT(*) FROM {P}sys.change_tracking_tables),
    {TEMPORAL},
    (SELECT COUNT(*)
       FROM {P}sys.tables t
       INNER JOIN {P}sys.schemas s ON s.schema_id = t.schema_id
      WHERE t.is_ms_shipped = 0
        AND s.name <> ''cdc''
        AND (t.name LIKE ''%water%mark%''
          OR t.name LIKE ''%high%water%''
          OR t.name LIKE ''%incremental%''
          OR t.name LIKE ''%etl%control%''
          OR t.name LIKE ''%load%control%''
          OR t.name LIKE ''%last%load%''
          OR t.name LIKE ''%delta%load%''
          OR t.name LIKE ''%etl%log%''
          OR t.name LIKE ''%load%log%'')),
    (SELECT COUNT(*)
       FROM {P}sys.columns c
       INNER JOIN {P}sys.tables t ON t.object_id = c.object_id
       INNER JOIN {P}sys.schemas s ON s.schema_id = t.schema_id
       INNER JOIN {P}sys.types ty ON ty.user_type_id = c.user_type_id
      WHERE t.is_ms_shipped = 0 AND s.name <> ''cdc'' AND ty.name = ''timestamp''),
    (SELECT COUNT(*)
       FROM {P}sys.columns c
       INNER JOIN {P}sys.tables t ON t.object_id = c.object_id
       INNER JOIN {P}sys.schemas s ON s.schema_id = t.schema_id
      WHERE t.is_ms_shipped = 0
        AND s.name <> ''cdc''
        AND (c.name LIKE ''%modified%date%''
          OR c.name LIKE ''%updated%date%''
          OR c.name LIKE ''%last%update%''
          OR c.name LIKE ''%change%date%''
          OR c.name LIKE ''%load%date%''
          OR c.name LIKE ''%row%version%''));';

DECLARE @db sysname, @prefix nvarchar(300), @cdcOn bit, @ctOn bit, @sql nvarchar(max);

IF @IsAzureSqlDb = 1
BEGIN
    SET @db = DB_NAME();
    SET @prefix = N'';

    SELECT @cdcOn = CASE WHEN EXISTS (SELECT 1 FROM sys.databases d WHERE d.database_id = DB_ID() AND d.is_cdc_enabled = 1) THEN 1 ELSE 0 END;
    SELECT @ctOn  = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_databases ctd WHERE ctd.database_id = DB_ID()) THEN 1 ELSE 0 END;

    SET @sql = REPLACE(@Template, N'{CDC}',
                   CASE WHEN @cdcOn = 1 THEN N'(SELECT COUNT(*) FROM {P}cdc.change_tables)' ELSE N'0' END);
    SET @sql = REPLACE(@sql, N'{TEMPORAL}',
                   CASE WHEN @SupportsTemporal = 1
                        THEN N'(SELECT COUNT(*) FROM {P}sys.tables t WHERE t.is_ms_shipped = 0 AND t.temporal_type = 2)'
                        ELSE N'0' END);
    SET @sql = REPLACE(@sql, N'{P}', @prefix);

    BEGIN TRY
        EXEC sp_executesql @sql, N'@DbName sysname, @CdcOn bit, @CtOn bit', @DbName = @db, @CdcOn = @cdcOn, @CtOn = @ctOn;
    END TRY
    BEGIN CATCH
        /* database not readable by the audit login - left out of the inventory */
    END CATCH
END
ELSE
BEGIN
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name,
               CASE WHEN d.is_cdc_enabled = 1 THEN 1 ELSE 0 END,
               CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_databases ctd WHERE ctd.database_id = d.database_id) THEN 1 ELSE 0 END
          FROM sys.databases d
         WHERE d.database_id > 4
           AND d.state = 0
           AND d.source_database_id IS NULL
           AND d.is_in_standby = 0
           AND HAS_DBACCESS(d.name) = 1;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db, @cdcOn, @ctOn;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @prefix = QUOTENAME(@db) + N'.';

        SET @sql = REPLACE(@Template, N'{CDC}',
                       CASE WHEN @cdcOn = 1 THEN N'(SELECT COUNT(*) FROM {P}cdc.change_tables)' ELSE N'0' END);
        SET @sql = REPLACE(@sql, N'{TEMPORAL}',
                       CASE WHEN @SupportsTemporal = 1
                            THEN N'(SELECT COUNT(*) FROM {P}sys.tables t WHERE t.is_ms_shipped = 0 AND t.temporal_type = 2)'
                            ELSE N'0' END);
        SET @sql = REPLACE(@sql, N'{P}', @prefix);

        BEGIN TRY
            EXEC sp_executesql @sql, N'@DbName sysname, @CdcOn bit, @CtOn bit', @DbName = @db, @CdcOn = @cdcOn, @CtOn = @ctOn;
        END TRY
        BEGIN CATCH
            /* database not readable by the audit login - left out of the inventory */
        END CATCH

        FETCH NEXT FROM db_cur INTO @db, @cdcOn, @ctOn;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

CREATE TABLE #Scored
(
    DatabaseName sysname       NOT NULL,
    Applicable   bit           NOT NULL,
    DbScore      int           NOT NULL,
    Detail       nvarchar(600) NOT NULL
);

INSERT INTO #Scored (DatabaseName, Applicable, DbScore, Detail)
SELECT
    i.DatabaseName,
    CASE WHEN i.UserTables = 0 THEN 0 ELSE 1 END,
    CASE
        WHEN i.UserTables = 0 THEN 3
        WHEN (i.CdcEnabled = 1 AND i.CdcCaptureInstances > 0)
          OR (i.CtEnabled = 1 AND i.CtTables > 0)
          OR i.TemporalTables > 0
          OR i.WatermarkTables > 0 THEN 3
        WHEN i.CdcEnabled = 1
          OR i.CtEnabled = 1
          OR i.RowVersionColumns > 0
          OR i.ChangeDateColumns > 0 THEN 2
        ELSE 1
    END,
    LEFT(CONCAT(
        i.DatabaseName,
        ' [tables=', i.UserTables,
        ', CDC=', CASE WHEN i.CdcEnabled = 1 THEN 'on' ELSE 'off' END, '/', i.CdcCaptureInstances,
        ', CT=', CASE WHEN i.CtEnabled = 1 THEN 'on' ELSE 'off' END, '/', i.CtTables,
        ', temporal=', i.TemporalTables,
        ', watermark=', i.WatermarkTables,
        ', rowversion=', i.RowVersionColumns,
        ', changedate=', i.ChangeDateColumns, ']'), 600)
FROM #Inc i;

DECLARE @Result           nvarchar(50);
DECLARE @Score            int;
DECLARE @DatabaseQueried  nvarchar(1000);
DECLARE @Finding          nvarchar(max);
DECLARE @Applicable       int;
DECLARE @PassCount        int;
DECLARE @PartialCount     int;
DECLARE @FailCount        int;
DECLARE @DbList           nvarchar(max);
DECLARE @FailList         nvarchar(max);
DECLARE @PartialList      nvarchar(max);
DECLARE @Detail           nvarchar(max);

SELECT
    @Applicable   = SUM(CASE WHEN s.Applicable = 1 THEN 1 ELSE 0 END),
    @PassCount    = SUM(CASE WHEN s.Applicable = 1 AND s.DbScore = 3 THEN 1 ELSE 0 END),
    @PartialCount = SUM(CASE WHEN s.Applicable = 1 AND s.DbScore = 2 THEN 1 ELSE 0 END),
    @FailCount    = SUM(CASE WHEN s.Applicable = 1 AND s.DbScore = 1 THEN 1 ELSE 0 END)
FROM #Scored s;

SET @Applicable   = ISNULL(@Applicable, 0);
SET @PassCount    = ISNULL(@PassCount, 0);
SET @PartialCount = ISNULL(@PartialCount, 0);
SET @FailCount    = ISNULL(@FailCount, 0);

SELECT @DbList = STUFF((SELECT N', ' + s.DatabaseName
                          FROM #Scored s
                         ORDER BY s.DatabaseName
                           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SELECT @FailList = STUFF((SELECT N', ' + s.DatabaseName
                            FROM #Scored s
                           WHERE s.Applicable = 1 AND s.DbScore = 1
                           ORDER BY s.DatabaseName
                             FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SELECT @PartialList = STUFF((SELECT N', ' + s.DatabaseName
                               FROM #Scored s
                              WHERE s.Applicable = 1 AND s.DbScore = 2
                              ORDER BY s.DatabaseName
                                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SELECT @Detail = STUFF((SELECT N'; ' + s.Detail
                          FROM #Scored s
                         ORDER BY s.DbScore, s.DatabaseName
                           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @Applicable = 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'No accessible user database containing user tables was found, so no incremental-load mechanism (watermark, CDC or Change Tracking) could be verified. Databases inspected: '
                   + ISNULL(@DbList, N'none') + N'.';
END
ELSE
BEGIN
    SELECT @Score = MIN(s.DbScore) FROM #Scored s WHERE s.Applicable = 1;

    SET @Finding = CONCAT(
        N'Applicable databases: ', @Applicable,
        N'. With a concrete incremental mechanism (CDC capture instances, tracked Change Tracking tables, temporal tables or watermark/ETL-control tables): ', @PassCount,
        N'. With capability only (CDC/CT enabled but nothing tracked, or only rowversion/change-date columns): ', @PartialCount,
        CASE WHEN @PartialCount > 0 THEN N' [' + LEFT(ISNULL(@PartialList, N''), 300) + N']' ELSE N'' END,
        N'. With no incremental-load artifact at all: ', @FailCount,
        CASE WHEN @FailCount > 0 THEN N' [' + LEFT(ISNULL(@FailList, N''), 300) + N']' ELSE N'' END,
        N'. Detail: ', LEFT(ISNULL(@Detail, N'none'), 1800), N'.');
END

SET @Result = CASE WHEN @Score = 3 THEN N'Pass' WHEN @Score = 2 THEN N'Partial' ELSE N'Fail' END;
SET @DatabaseQueried = LEFT(ISNULL(@DbList, CAST(DB_NAME() AS nvarchar(128))), 1000);

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

DROP TABLE #Scored;
DROP TABLE #Inc;