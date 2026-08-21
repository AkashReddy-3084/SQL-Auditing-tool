SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF OBJECT_ID('tempdb..#OwnerCoverage') IS NOT NULL
    DROP TABLE #OwnerCoverage;

CREATE TABLE #OwnerCoverage
(
    DatabaseName    SYSNAME NOT NULL,
    TotalTables     INT     NOT NULL,
    TablesWithOwner INT     NOT NULL
);

DECLARE @db  SYSNAME;
DECLARE @sql NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: cross-database queries are unsupported, so only the connected database is scanned.
    INSERT INTO #OwnerCoverage (DatabaseName, TotalTables, TablesWithOwner)
    SELECT DB_NAME(),
           COUNT(*),
           ISNULL(SUM(CASE WHEN EXISTS
                (
                    SELECT 1
                    FROM sys.extended_properties AS ep
                    WHERE ep.class    = 1
                      AND ep.major_id = t.object_id
                      AND ep.minor_id = 0
                      AND (ep.name LIKE '%owner%' OR ep.name LIKE '%steward%' OR ep.name LIKE '%custodian%')
                      AND LEN(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(4000), ep.value), N'')))) > 0
                ) THEN 1 ELSE 0 END), 0)
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND s.name <> 'sys';
END
ELSE
BEGIN
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
        SELECT @dbOut,
               COUNT(*),
               ISNULL(SUM(CASE WHEN EXISTS
                    (
                        SELECT 1
                        FROM ' + QUOTENAME(@db) + N'.sys.extended_properties AS ep
                        WHERE ep.class    = 1
                          AND ep.major_id = t.object_id
                          AND ep.minor_id = 0
                          AND (ep.name LIKE ''%owner%'' OR ep.name LIKE ''%steward%'' OR ep.name LIKE ''%custodian%'')
                          AND LEN(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(4000), ep.value), N'''')))) > 0
                    ) THEN 1 ELSE 0 END), 0)
        FROM ' + QUOTENAME(@db) + N'.sys.tables AS t
        INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
          AND s.name <> ''sys'';';

        BEGIN TRY
            INSERT INTO #OwnerCoverage (DatabaseName, TotalTables, TablesWithOwner)
            EXEC sp_executesql @sql, N'@dbOut SYSNAME', @dbOut = @db;
        END TRY
        BEGIN CATCH
            -- Database unreadable (offline, restoring or access denied): skip it.
        END CATCH

        FETCH NEXT FROM db_cur INTO @db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @DbCount    INT = (SELECT COUNT(*) FROM #OwnerCoverage);
DECLARE @Total      INT = (SELECT ISNULL(SUM(TotalTables), 0) FROM #OwnerCoverage);
DECLARE @WithOwner  INT = (SELECT ISNULL(SUM(TablesWithOwner), 0) FROM #OwnerCoverage);
DECLARE @Missing    INT = @Total - @WithOwner;
DECLARE @Pct        DECIMAL(5, 2) = CASE WHEN @Total = 0 THEN 100.00
                                         ELSE CAST(@WithOwner * 100.0 / @Total AS DECIMAL(5, 2)) END;

DECLARE @DbList NVARCHAR(MAX) =
(
    SELECT STUFF((
        SELECT N', ' + oc.DatabaseName
        FROM #OwnerCoverage AS oc
        ORDER BY oc.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'')
);

DECLARE @WorstList NVARCHAR(MAX) =
(
    SELECT STUFF((
        SELECT TOP (5) N', ' + oc.DatabaseName + N' (' + CAST(oc.TotalTables - oc.TablesWithOwner AS NVARCHAR(20)) + N' of '
               + CAST(oc.TotalTables AS NVARCHAR(20)) + N' unowned)'
        FROM #OwnerCoverage AS oc
        WHERE oc.TotalTables > oc.TablesWithOwner
        ORDER BY (oc.TotalTables - oc.TablesWithOwner) DESC, oc.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'')
);

DECLARE @Result  NVARCHAR(20);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(MAX);

IF @DbCount = 0
BEGIN
    SET @Result  = N'NeedsReview';
    SET @Score   = 0;
    SET @Finding = N'No accessible user database was found, so table data ownership could not be assessed. Verify permissions and re-run, or review the data ownership register manually.';
END
ELSE IF @Total = 0
BEGIN
    SET @Result  = N'Pass';
    SET @Score   = 3;
    SET @Finding = N'No user tables exist in the ' + CAST(@DbCount AS NVARCHAR(20)) + N' scanned user database(s), so there is no dataset lacking a defined data owner.';
END
ELSE
BEGIN
    SET @Score = CASE
                    WHEN @Pct >= 100.00 THEN 3
                    WHEN @Pct >= 80.00  THEN 2
                    WHEN @Pct >= 50.00  THEN 1
                    ELSE 0
                 END;
    SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

    SET @Finding = CAST(@WithOwner AS NVARCHAR(20)) + N' of ' + CAST(@Total AS NVARCHAR(20))
                 + N' user tables (' + CAST(@Pct AS NVARCHAR(20)) + N'%) across ' + CAST(@DbCount AS NVARCHAR(20))
                 + N' database(s) carry a non-empty owner/steward/custodian extended property; '
                 + CAST(@Missing AS NVARCHAR(20)) + N' table(s) have no recorded data owner.'
                 + CASE WHEN @WorstList IS NULL THEN N''
                        ELSE N' Largest gaps: ' + @WorstList + N'.' END;
END

SELECT @Result                      AS Result,
       @Score                       AS Score,
       ISNULL(@DbList, N'None')     AS DatabaseQueried,
       @Finding                     AS Finding;

IF OBJECT_ID('tempdb..#OwnerCoverage') IS NOT NULL
    DROP TABLE #OwnerCoverage;