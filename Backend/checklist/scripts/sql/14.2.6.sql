/*
    Checklist Item : 14.2.6 - Fill factor tuned for volatile tables where needed
    Area           : Performance & Query Tuning
    Scope          : DATABASE
    Script Type    : SQL (read-only)

    Reads sys.indexes / sys.dm_db_partition_stats / sys.dm_db_index_operational_stats only.
    No data, schema or configuration is modified.
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @IsAzureDb BIT =
    CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#IdxFill') IS NOT NULL
    DROP TABLE #IdxFill;

CREATE TABLE #IdxFill
(
    DatabaseName  SYSNAME NOT NULL,
    SchemaName    SYSNAME NOT NULL,
    TableName     SYSNAME NOT NULL,
    IndexName     SYSNAME NULL,
    FillFactorPct TINYINT NOT NULL,
    TableRows     BIGINT  NOT NULL,
    ModCount      BIGINT  NOT NULL,
    AllocCount    BIGINT  NOT NULL
);

DECLARE @Collect NVARCHAR(MAX) = N'
SELECT
    DB_NAME()               AS DatabaseName,
    s.name                  AS SchemaName,
    t.name                  AS TableName,
    i.name                  AS IndexName,
    i.fill_factor           AS FillFactorPct,
    ISNULL(r.TableRows, 0)  AS TableRows,
    ISNULL(o.ModCount, 0)   AS ModCount,
    ISNULL(o.AllocCount, 0) AS AllocCount
FROM sys.indexes AS i
INNER JOIN sys.tables  AS t ON t.object_id = i.object_id
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
LEFT JOIN
(
    SELECT ps.object_id, SUM(ps.row_count) AS TableRows
    FROM sys.dm_db_partition_stats AS ps
    WHERE ps.index_id IN (0, 1)
    GROUP BY ps.object_id
) AS r ON r.object_id = i.object_id
LEFT JOIN
(
    SELECT
        os.object_id,
        os.index_id,
        SUM(os.leaf_insert_count + os.leaf_update_count + os.leaf_delete_count) AS ModCount,
        SUM(os.leaf_allocation_count + os.nonleaf_allocation_count)             AS AllocCount
    FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
    GROUP BY os.object_id, os.index_id
) AS o ON o.object_id = i.object_id AND o.index_id = i.index_id
WHERE i.index_id > 0
  AND i.type IN (1, 2)
  AND i.is_hypothetical = 0
  AND i.is_disabled = 0
  AND i.data_space_id > 0
  AND t.is_ms_shipped = 0;';

IF @IsAzureDb = 1
BEGIN
    BEGIN TRY
        INSERT INTO #IdxFill
            (DatabaseName, SchemaName, TableName, IndexName, FillFactorPct, TableRows, ModCount, AllocCount)
        EXEC sys.sp_executesql @Collect;
    END TRY
    BEGIN CATCH
        /* database not readable by this login - excluded from the sample */
    END CATCH
END
ELSE
BEGIN
    DECLARE @DbName SYSNAME;
    DECLARE @Sql    NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.is_read_only = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
          AND DATABASEPROPERTYEX(d.name, 'Updateability') = 'READ_WRITE'
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N'; ' + @Collect;

            INSERT INTO #IdxFill
                (DatabaseName, SchemaName, TableName, IndexName, FillFactorPct, TableRows, ModCount, AllocCount)
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            /* database unavailable or insufficient permission - skipped */
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @DbCount         INT = (SELECT COUNT(DISTINCT DatabaseName) FROM #IdxFill);
DECLARE @TotalIdx        INT = (SELECT COUNT(*) FROM #IdxFill);
DECLARE @TunedIdx        INT = (SELECT COUNT(*) FROM #IdxFill WHERE FillFactorPct BETWEEN 1 AND 99);
DECLARE @VolatileIdx     INT = (SELECT COUNT(*) FROM #IdxFill WHERE TableRows >= 10000 AND ModCount >= 1000);
DECLARE @VolatileUntuned INT = (SELECT COUNT(*) FROM #IdxFill
                                WHERE TableRows >= 10000
                                  AND ModCount >= 1000
                                  AND (FillFactorPct = 0 OR FillFactorPct = 100));

DECLARE @DbList NVARCHAR(MAX) =
    ISNULL(STUFF((
        SELECT N', ' + x.DatabaseName
        FROM (SELECT DISTINCT DatabaseName FROM #IdxFill) AS x
        ORDER BY x.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'No accessible user databases');

DECLARE @Examples NVARCHAR(MAX) =
    ISNULL(STUFF((
        SELECT TOP (5)
               N'; ' + f.DatabaseName + N'.' + f.SchemaName + N'.' + f.TableName
             + N' [' + ISNULL(f.IndexName, N'(unnamed)') + N']'
             + N' rows=' + CONVERT(NVARCHAR(20), f.TableRows)
             + N' mods=' + CONVERT(NVARCHAR(20), f.ModCount)
             + N' fillfactor=' + CONVERT(NVARCHAR(5), f.FillFactorPct)
        FROM #IdxFill AS f
        WHERE f.TableRows >= 10000
          AND f.ModCount >= 1000
          AND (f.FillFactorPct = 0 OR f.FillFactorPct = 100)
        ORDER BY f.ModCount DESC
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @Result  NVARCHAR(20);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(MAX);

IF @TotalIdx = 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'No rowstore indexes on user tables were found in the accessible user databases ('
                 + CONVERT(NVARCHAR(10), @DbCount) + N' database(s) scanned), so fill factor tuning is not applicable.';
END
ELSE IF @VolatileIdx = 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'Scanned ' + CONVERT(NVARCHAR(10), @DbCount) + N' user database(s) and '
                 + CONVERT(NVARCHAR(10), @TotalIdx) + N' rowstore index(es). No index qualifies as volatile '
                 + N'(no index on a table of 10,000+ rows has recorded 1,000+ leaf inserts/updates/deletes), so no fill factor tuning is required. '
                 + CONVERT(NVARCHAR(10), @TunedIdx) + N' index(es) already carry a non-default fill factor.';
END
ELSE IF @VolatileUntuned = 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'Scanned ' + CONVERT(NVARCHAR(10), @DbCount) + N' user database(s) and '
                 + CONVERT(NVARCHAR(10), @TotalIdx) + N' rowstore index(es). All '
                 + CONVERT(NVARCHAR(10), @VolatileIdx) + N' volatile index(es) carry a tuned fill factor between 1 and 99; '
                 + CONVERT(NVARCHAR(10), @TunedIdx) + N' index(es) in total are tuned.';
END
ELSE IF @TunedIdx > 0
BEGIN
    SET @Score  = 2;
    SET @Finding = N'Scanned ' + CONVERT(NVARCHAR(10), @DbCount) + N' user database(s) and '
                 + CONVERT(NVARCHAR(10), @TotalIdx) + N' rowstore index(es). Fill factor tuning is in use ('
                 + CONVERT(NVARCHAR(10), @TunedIdx) + N' index(es) set between 1 and 99) but '
                 + CONVERT(NVARCHAR(10), @VolatileUntuned) + N' of ' + CONVERT(NVARCHAR(10), @VolatileIdx)
                 + N' volatile index(es) remain at the default fill factor. Examples: ' + @Examples + N'.';
END
ELSE
BEGIN
    SET @Score  = 1;
    SET @Finding = N'Scanned ' + CONVERT(NVARCHAR(10), @DbCount) + N' user database(s) and '
                 + CONVERT(NVARCHAR(10), @TotalIdx) + N' rowstore index(es). No index anywhere carries a non-default fill factor, '
                 + N'yet ' + CONVERT(NVARCHAR(10), @VolatileIdx) + N' volatile index(es) exist on tables of 10,000+ rows with 1,000+ leaf modifications. '
                 + N'Fill factor has not been tuned for volatile tables. Examples: ' + @Examples + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @DbList  AS DatabaseQueried,
    @Finding AS Finding;

IF OBJECT_ID('tempdb..#IdxFill') IS NOT NULL
    DROP TABLE #IdxFill;