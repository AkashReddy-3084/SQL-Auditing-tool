SET NOCOUNT ON;

BEGIN TRY

    IF OBJECT_ID('tempdb..#Pat') IS NOT NULL DROP TABLE #Pat;
    IF OBJECT_ID('tempdb..#Hits') IS NOT NULL DROP TABLE #Hits;
    IF OBJECT_ID('tempdb..#ScannedDb') IS NOT NULL DROP TABLE #ScannedDb;

    CREATE TABLE #Pat
    (
        Kind    VARCHAR(10)   NOT NULL,
        Pattern NVARCHAR(100) NOT NULL
    );

    CREATE TABLE #Hits
    (
        DatabaseName SYSNAME       NOT NULL,
        Kind         VARCHAR(20)   NOT NULL,
        ObjectName   NVARCHAR(300) NOT NULL
    );

    CREATE TABLE #ScannedDb
    (
        DatabaseName SYSNAME NOT NULL
    );

    -- NAME = restart/checkpoint control artifacts identified by table or column name
    INSERT INTO #Pat (Kind, Pattern) VALUES
        ('NAME', N'%checkpoint%'),
        ('NAME', N'%restart%'),
        ('NAME', N'%resume%'),
        ('NAME', N'%watermark%'),
        ('NAME', N'%water[_]mark%'),
        ('NAME', N'%highwater%'),
        ('NAME', N'%high[_]water%'),
        ('NAME', N'%lastprocessed%'),
        ('NAME', N'%last[_]processed%'),
        ('NAME', N'%lastsuccess%'),
        ('NAME', N'%last[_]success%'),
        ('NAME', N'%lastload%'),
        ('NAME', N'%last[_]load%'),
        ('NAME', N'%lastrun%'),
        ('NAME', N'%last[_]run%'),
        ('NAME', N'%isprocessed%'),
        ('NAME', N'%is[_]processed%'),
        ('NAME', N'%processedflag%'),
        ('NAME', N'%processed[_]flag%'),
        ('NAME', N'%stepstatus%'),
        ('NAME', N'%step[_]status%'),
        ('NAME', N'%batchstatus%'),
        ('NAME', N'%batch[_]status%'),
        ('NAME', N'%loadstatus%'),
        ('NAME', N'%load[_]status%'),
        ('NAME', N'%loadcontrol%'),
        ('NAME', N'%load[_]control%'),
        ('NAME', N'%batchcontrol%'),
        ('NAME', N'%batch[_]control%'),
        ('NAME', N'%etlcontrol%'),
        ('NAME', N'%etl[_]control%');

    -- DEFN = restart markers referenced inside module bodies; deliberately narrower than NAME
    -- so the bare CHECKPOINT statement is not counted as restart logic
    INSERT INTO #Pat (Kind, Pattern) VALUES
        ('DEFN', N'%checkpointid%'),
        ('DEFN', N'%checkpoint[_]id%'),
        ('DEFN', N'%restartpoint%'),
        ('DEFN', N'%restart[_]point%'),
        ('DEFN', N'%resumefrom%'),
        ('DEFN', N'%resume[_]from%'),
        ('DEFN', N'%watermark%'),
        ('DEFN', N'%water[_]mark%'),
        ('DEFN', N'%highwater%'),
        ('DEFN', N'%high[_]water%'),
        ('DEFN', N'%lastprocessed%'),
        ('DEFN', N'%last[_]processed%'),
        ('DEFN', N'%lastsuccess%'),
        ('DEFN', N'%last[_]success%'),
        ('DEFN', N'%lastload%'),
        ('DEFN', N'%last[_]load%'),
        ('DEFN', N'%lastrun%'),
        ('DEFN', N'%last[_]run%'),
        ('DEFN', N'%isprocessed%'),
        ('DEFN', N'%is[_]processed%'),
        ('DEFN', N'%processedflag%'),
        ('DEFN', N'%processed[_]flag%'),
        ('DEFN', N'%stepstatus%'),
        ('DEFN', N'%step[_]status%'),
        ('DEFN', N'%batchstatus%'),
        ('DEFN', N'%batch[_]status%'),
        ('DEFN', N'%loadstatus%'),
        ('DEFN', N'%load[_]status%');

    -- ETL = modules that look like load routines, used only to tell "ETL with no restart
    -- evidence" apart from "no in-database ETL at all"
    INSERT INTO #Pat (Kind, Pattern) VALUES
        ('ETL', N'load%'),
        ('ETL', N'%[_]load%'),
        ('ETL', N'%etl%'),
        ('ETL', N'%import%'),
        ('ETL', N'%staging%'),
        ('ETL', N'%ingest%'),
        ('ETL', N'%upsert%'),
        ('ETL', N'%extract%'),
        ('ETL', N'%datafeed%');

    DECLARE @Body NVARCHAR(MAX) = N'
INSERT INTO #Hits (DatabaseName, Kind, ObjectName)
SELECT DB_NAME(), ''RestartTable'', t.name
FROM sys.tables AS t
WHERE t.is_ms_shipped = 0
  AND EXISTS (SELECT 1 FROM #Pat AS p WHERE p.Kind = ''NAME'' AND t.name LIKE p.Pattern);

INSERT INTO #Hits (DatabaseName, Kind, ObjectName)
SELECT DISTINCT DB_NAME(), ''RestartColumn'', t.name + N''.'' + c.name
FROM sys.columns AS c
INNER JOIN sys.tables AS t ON t.object_id = c.object_id
WHERE t.is_ms_shipped = 0
  AND EXISTS (SELECT 1 FROM #Pat AS p WHERE p.Kind = ''NAME'' AND c.name LIKE p.Pattern);

INSERT INTO #Hits (DatabaseName, Kind, ObjectName)
SELECT DB_NAME(), ''RestartModule'', o.name
FROM sys.sql_modules AS m
INNER JOIN sys.objects AS o ON o.object_id = m.object_id
WHERE o.is_ms_shipped = 0
  AND m.definition IS NOT NULL
  AND EXISTS (SELECT 1 FROM #Pat AS p WHERE p.Kind = ''DEFN'' AND m.definition LIKE p.Pattern);

INSERT INTO #Hits (DatabaseName, Kind, ObjectName)
SELECT DB_NAME(), ''EtlModule'', o.name
FROM sys.objects AS o
WHERE o.is_ms_shipped = 0
  AND o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'')
  AND EXISTS (SELECT 1 FROM #Pat AS p WHERE p.Kind = ''ETL'' AND o.name LIKE p.Pattern);
';

    DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

    IF @EngineEdition = 5
    BEGIN
        -- Azure SQL Database: no cross-database access, evaluate the current database only
        BEGIN TRY
            EXEC sys.sp_executesql @Body;
            INSERT INTO #ScannedDb (DatabaseName) VALUES (DB_NAME());
        END TRY
        BEGIN CATCH
            PRINT 'Skipped database ' + DB_NAME() + ': ' + ERROR_MESSAGE();
        END CATCH
    END
    ELSE
    BEGIN
        DECLARE @Db SYSNAME;
        DECLARE @Sql NVARCHAR(MAX);

        DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT d.name
            FROM sys.databases AS d
            WHERE d.database_id > 4
              AND d.state = 0
              AND d.source_database_id IS NULL
              AND d.is_in_standby = 0
              AND HAS_DBACCESS(d.name) = 1
            ORDER BY d.name;

        OPEN db_cur;
        FETCH NEXT FROM db_cur INTO @Db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'USE ' + QUOTENAME(@Db) + N'; ' + @Body;
                EXEC sys.sp_executesql @Sql;
                INSERT INTO #ScannedDb (DatabaseName) VALUES (@Db);
            END TRY
            BEGIN CATCH
                PRINT 'Skipped database ' + @Db + ': ' + ERROR_MESSAGE();
            END CATCH

            FETCH NEXT FROM db_cur INTO @Db;
        END

        CLOSE db_cur;
        DEALLOCATE db_cur;
    END

    DECLARE @DbTotal INT = 0,
            @DbCtl   INT = 0,
            @DbMod   INT = 0,
            @DbEtl   INT = 0,
            @DbBoth  INT = 0;

    SELECT @DbTotal = COUNT(*) FROM #ScannedDb;

    SELECT
        @DbCtl  = ISNULL(SUM(CASE WHEN x.CtlCnt > 0 THEN 1 ELSE 0 END), 0),
        @DbMod  = ISNULL(SUM(CASE WHEN x.ModCnt > 0 THEN 1 ELSE 0 END), 0),
        @DbEtl  = ISNULL(SUM(CASE WHEN x.EtlCnt > 0 THEN 1 ELSE 0 END), 0),
        @DbBoth = ISNULL(SUM(CASE WHEN x.CtlCnt > 0 AND x.ModCnt > 0 THEN 1 ELSE 0 END), 0)
    FROM
    (
        SELECT
            d.DatabaseName,
            SUM(CASE WHEN h.Kind IN ('RestartTable', 'RestartColumn') THEN 1 ELSE 0 END) AS CtlCnt,
            SUM(CASE WHEN h.Kind = 'RestartModule' THEN 1 ELSE 0 END) AS ModCnt,
            SUM(CASE WHEN h.Kind = 'EtlModule' THEN 1 ELSE 0 END) AS EtlCnt
        FROM #ScannedDb AS d
        LEFT JOIN #Hits AS h ON h.DatabaseName = d.DatabaseName
        GROUP BY d.DatabaseName
    ) AS x;

    DECLARE @DbList NVARCHAR(1000) =
        ISNULL(STUFF((
            SELECT TOP (30) N', ' + d.DatabaseName
            FROM #ScannedDb AS d
            ORDER BY d.DatabaseName
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N''), N'None');

    DECLARE @Sample NVARCHAR(1000) =
        ISNULL(STUFF((
            SELECT TOP (8) N'; ' + h.DatabaseName + N'.' + h.ObjectName + N' [' + h.Kind + N']'
            FROM #Hits AS h
            WHERE h.Kind <> 'EtlModule'
            ORDER BY h.Kind, h.DatabaseName, h.ObjectName
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N''), N'none');

    DECLARE @Result  NVARCHAR(20);
    DECLARE @Score   INT;
    DECLARE @Finding NVARCHAR(4000);

    IF @DbTotal = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'No accessible user database was found, so restart-from-point-of-failure behaviour could not be confirmed from engine metadata. Manual review of the ETL orchestration platform is required.';
    END
    ELSE IF @DbBoth > 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Restart/checkpoint control artifacts and restart-aware ETL module logic were both found in ' + CAST(@DbBoth AS NVARCHAR(10))
            + N' of ' + CAST(@DbTotal AS NVARCHAR(10)) + N' scanned user database(s). Control artifacts exist in ' + CAST(@DbCtl AS NVARCHAR(10))
            + N' database(s) and modules referencing restart markers exist in ' + CAST(@DbMod AS NVARCHAR(10))
            + N' database(s), indicating failed loads can resume from a recorded point rather than requiring a full re-run. Evidence: ' + @Sample + N'.';
    END
    ELSE IF @DbCtl > 0 OR @DbMod > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Restart evidence is only partial across ' + CAST(@DbTotal AS NVARCHAR(10)) + N' scanned user database(s): '
            + CAST(@DbCtl AS NVARCHAR(10)) + N' database(s) contain restart/checkpoint control artifacts and '
            + CAST(@DbMod AS NVARCHAR(10)) + N' database(s) contain modules referencing restart markers, but no single database has both. '
            + N'Restart state may be recorded without being consumed by the load logic, or advanced without a durable control structure. Evidence: ' + @Sample + N'.';
    END
    ELSE IF @DbEtl > 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'ETL-style modules were found in ' + CAST(@DbEtl AS NVARCHAR(10)) + N' of ' + CAST(@DbTotal AS NVARCHAR(10))
            + N' scanned user database(s), but no restart/checkpoint control table, no restart marker column and no module referencing a restart marker were found anywhere. '
            + N'A failed load therefore appears to require a full re-run rather than resuming from the point of failure.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'No in-database ETL modules and no restart/checkpoint control artifacts were found across ' + CAST(@DbTotal AS NVARCHAR(10))
            + N' scanned user database(s). Loads are likely orchestrated outside the engine (for example SSIS checkpoints, Azure Data Factory or an external scheduler), '
            + N'so restart-from-point-of-failure behaviour cannot be confirmed from T-SQL and needs manual review.';
    END

    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    SELECT
        @Result  AS Result,
        @Score   AS Score,
        @DbList  AS DatabaseQueried,
        @Finding AS Finding;

    IF OBJECT_ID('tempdb..#Pat') IS NOT NULL DROP TABLE #Pat;
    IF OBJECT_ID('tempdb..#Hits') IS NOT NULL DROP TABLE #Hits;
    IF OBJECT_ID('tempdb..#ScannedDb') IS NOT NULL DROP TABLE #ScannedDb;

END TRY
BEGIN CATCH

    IF CURSOR_STATUS('local', 'db_cur') >= 0
    BEGIN
        CLOSE db_cur;
        DEALLOCATE db_cur;
    END

    SELECT
        'Fail' AS Result,
        0 AS Score,
        ISNULL(DB_NAME(), 'Unknown') AS DatabaseQueried,
        CAST(N'Check 2.3.2 could not be completed: ' + ERROR_MESSAGE() AS NVARCHAR(4000)) AS Finding;

END CATCH