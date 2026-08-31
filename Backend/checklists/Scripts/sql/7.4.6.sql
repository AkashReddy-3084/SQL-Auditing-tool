-- Checklist 7.4.6 - Temporal tables / change tracking used for data history where required
-- Read-only: catalog views only, no configuration or data changes.
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @HasTemporal   BIT = CASE WHEN COL_LENGTH('sys.tables', 'temporal_type') IS NOT NULL THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#DbHistory') IS NOT NULL DROP TABLE #DbHistory;
CREATE TABLE #DbHistory
(
    DatabaseName         SYSNAME NOT NULL,
    UserTableCount       INT     NOT NULL DEFAULT (0),
    TemporalTableCount   INT     NOT NULL DEFAULT (0),
    ChangeTrackingDb     INT     NOT NULL DEFAULT (0),
    ChangeTrackingTables INT     NOT NULL DEFAULT (0),
    CdcEnabled           INT     NOT NULL DEFAULT (0),
    CdcCaptureTables     INT     NOT NULL DEFAULT (0)
);

DECLARE @sql NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: cross-database queries are not possible, inspect the current database only.
    SET @sql = N'
INSERT INTO #DbHistory (DatabaseName, UserTableCount, TemporalTableCount, ChangeTrackingDb, ChangeTrackingTables, CdcEnabled, CdcCaptureTables)
SELECT DB_NAME(),
       (SELECT COUNT(*) FROM sys.tables t WHERE t.is_ms_shipped = 0 AND t.name <> ''sysdiagrams''' + CASE WHEN @HasTemporal = 1 THEN N' AND t.temporal_type <> 1' ELSE N'' END + N'),
       ' + CASE WHEN @HasTemporal = 1 THEN N'(SELECT COUNT(*) FROM sys.tables t2 WHERE t2.is_ms_shipped = 0 AND t2.temporal_type = 2)' ELSE N'0' END + N',
       (SELECT COUNT(*) FROM sys.change_tracking_databases ctd WHERE ctd.database_id = DB_ID()),
       (SELECT COUNT(*) FROM sys.change_tracking_tables),
       ' + CASE WHEN OBJECT_ID('cdc.change_tables') IS NOT NULL THEN N'1' ELSE N'0' END + N',
       ' + CASE WHEN OBJECT_ID('cdc.change_tables') IS NOT NULL THEN N'(SELECT COUNT(*) FROM cdc.change_tables)' ELSE N'0' END + N';';

    BEGIN TRY
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbHistory (DatabaseName) VALUES (DB_NAME());
    END CATCH
END
ELSE
BEGIN
    DECLARE @DbName SYSNAME;
    DECLARE @IsCdc  BIT;

    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name, CAST(ISNULL(d.is_cdc_enabled, 0) AS BIT)
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.source_database_id IS NULL          -- exclude database snapshots
          AND d.state = 0                            -- ONLINE only
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @DbName, @IsCdc;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
INSERT INTO #DbHistory (DatabaseName, UserTableCount, TemporalTableCount, ChangeTrackingDb, ChangeTrackingTables, CdcEnabled, CdcCaptureTables)
SELECT ' + QUOTENAME(@DbName, '''') + N',
       (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables t WHERE t.is_ms_shipped = 0 AND t.name <> ''sysdiagrams''' + CASE WHEN @HasTemporal = 1 THEN N' AND t.temporal_type <> 1' ELSE N'' END + N'),
       ' + CASE WHEN @HasTemporal = 1 THEN N'(SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables t2 WHERE t2.is_ms_shipped = 0 AND t2.temporal_type = 2)' ELSE N'0' END + N',
       (SELECT COUNT(*) FROM sys.change_tracking_databases ctd WHERE ctd.database_id = DB_ID(' + QUOTENAME(@DbName, '''') + N')),
       (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.change_tracking_tables),
       ' + CASE WHEN @IsCdc = 1 THEN N'1' ELSE N'0' END + N',
       ' + CASE WHEN @IsCdc = 1 THEN N'(SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.cdc.change_tables)' ELSE N'0' END + N';';

        BEGIN TRY
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            -- Database could not be inspected (permissions / transient state); recorded with zero counts.
            INSERT INTO #DbHistory (DatabaseName) VALUES (@DbName);
        END CATCH

        FETCH NEXT FROM db_cur INTO @DbName, @IsCdc;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @CandidateDbs  INT = 0,
        @CoveredDbs    INT = 0,
        @TotalTemporal INT = 0,
        @TotalCt       INT = 0,
        @TotalCdc      INT = 0,
        @CtDbs         INT = 0;

SELECT @CandidateDbs = COUNT(*)
FROM #DbHistory
WHERE UserTableCount > 0;

SELECT @CoveredDbs = COUNT(*)
FROM #DbHistory
WHERE UserTableCount > 0
  AND (TemporalTableCount > 0 OR ChangeTrackingTables > 0 OR CdcCaptureTables > 0);

SELECT @TotalTemporal = ISNULL(SUM(TemporalTableCount), 0),
       @TotalCt       = ISNULL(SUM(ChangeTrackingTables), 0),
       @TotalCdc      = ISNULL(SUM(CdcCaptureTables), 0),
       @CtDbs         = ISNULL(SUM(CASE WHEN ChangeTrackingDb > 0 THEN 1 ELSE 0 END), 0)
FROM #DbHistory;

DECLARE @CoveredList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT ', ' + h.DatabaseName
                  FROM #DbHistory AS h
                  WHERE h.UserTableCount > 0
                    AND (h.TemporalTableCount > 0 OR h.ChangeTrackingTables > 0 OR h.CdcCaptureTables > 0)
                  ORDER BY h.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), 'none');

DECLARE @UncoveredList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT ', ' + h.DatabaseName
                  FROM #DbHistory AS h
                  WHERE h.UserTableCount > 0
                    AND h.TemporalTableCount = 0
                    AND h.ChangeTrackingTables = 0
                    AND h.CdcCaptureTables = 0
                  ORDER BY h.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), 'none');

DECLARE @QueriedList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT ', ' + h.DatabaseName
                  FROM #DbHistory AS h
                  ORDER BY h.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), 'N/A');

DECLARE @Result          NVARCHAR(20),
        @Score           INT,
        @Finding         NVARCHAR(MAX),
        @DatabaseQueried NVARCHAR(400) = LEFT(@QueriedList, 400);

DECLARE @Mechanisms NVARCHAR(400) =
    N'Temporal tables: ' + CAST(@TotalTemporal AS NVARCHAR(20))
  + N'; Change Tracking tables: ' + CAST(@TotalCt AS NVARCHAR(20))
  + N' (CT enabled on ' + CAST(@CtDbs AS NVARCHAR(20)) + N' database(s))'
  + N'; CDC capture instances: ' + CAST(@TotalCdc AS NVARCHAR(20)) + N'.';

IF @CandidateDbs = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No accessible online user database containing user tables was found, so data-history coverage could not be measured. Databases inspected: ' + LEFT(@QueriedList, 500) + N'. Manual review required against the data-retention/regulatory policy.';
END
ELSE IF @CoveredDbs = @CandidateDbs
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CAST(@CandidateDbs AS NVARCHAR(20)) + N' user database(s) with user tables implement at least one data-history mechanism. ' + @Mechanisms + N' Covered databases: ' + LEFT(@CoveredList, 500) + N'. Confirm against the data-retention policy that every table requiring history is among the tracked objects.';
END
ELSE IF @CoveredDbs > 0
BEGIN
    SET @Score = 2;
    SET @Finding = CAST(@CoveredDbs AS NVARCHAR(20)) + N' of ' + CAST(@CandidateDbs AS NVARCHAR(20)) + N' user database(s) with user tables implement a data-history mechanism. ' + @Mechanisms + N' Covered: ' + LEFT(@CoveredList, 400) + N'. Not covered: ' + LEFT(@UncoveredList, 400) + N'.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'None of the ' + CAST(@CandidateDbs AS NVARCHAR(20)) + N' user database(s) with user tables use temporal tables, Change Tracking or Change Data Capture. ' + @Mechanisms + N' Databases without any history mechanism: ' + LEFT(@UncoveredList, 500) + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#DbHistory') IS NOT NULL DROP TABLE #DbHistory;