-- Checklist: [Partitioning & Storage] Archival/purge process exists for aged data
-- Scope: DATABASE
-- Scoring: 3 = purge/retention modules plus archive tables or partitioning, and every large table is partitioned; 2 = at least two evidence categories present but large tables are not all covered; 1 = only one evidence category present; 0 = user tables exist with no archival or purge evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Archival and purge evidence could not be collected in the current database';

DECLARE @DeletePattern NVARCHAR(60) = '%' + CHAR(68) + 'ELETE%';
DECLARE @TruncPattern  NVARCHAR(60) = '%' + CHAR(84) + 'RUNCATE%';
DECLARE @SwitchPattern NVARCHAR(60) = '%SWITCH%PARTITION%';

DECLARE @TableCount INT = 0;
DECLARE @ArchiveTables INT = 0;
DECLARE @PurgeModules INT = 0;
DECLARE @PartitionSchemes INT = 0;
DECLARE @LargeTables INT = 0;
DECLARE @LargeCovered INT = 0;
DECLARE @Categories INT = 0;
DECLARE @ArchiveList NVARCHAR(MAX) = 'none';
DECLARE @PurgeList NVARCHAR(MAX) = 'none';

DECLARE @Big TABLE (ObjectId INT PRIMARY KEY, TableName NVARCHAR(300), PartCount INT);

BEGIN TRY
    SELECT @TableCount = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;

    SELECT @ArchiveTables = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND (name LIKE '%archive%' OR name LIKE '%[_]hist' OR name LIKE '%history%'
           OR name LIKE '%purge%' OR name LIKE '%retention%');

    SET @ArchiveList = ISNULL(LEFT((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + '.' + t.name), ', ')
                                    FROM sys.tables AS t
                                    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
                                    WHERE t.is_ms_shipped = 0
                                      AND (t.name LIKE '%archive%' OR t.name LIKE '%[_]hist'
                                           OR t.name LIKE '%history%' OR t.name LIKE '%purge%'
                                           OR t.name LIKE '%retention%')), 500), 'none');

    SELECT @PurgeModules = COUNT(*)
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o ON o.object_id = m.object_id
    WHERE o.is_ms_shipped = 0
      AND (o.name LIKE '%purge%' OR o.name LIKE '%archive%' OR o.name LIKE '%retention%'
           OR m.definition LIKE '%retention%' OR m.definition LIKE '%archive%')
      AND (m.definition LIKE @DeletePattern OR m.definition LIKE @TruncPattern
           OR m.definition LIKE @SwitchPattern);

    SET @PurgeList = ISNULL(LEFT((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + '.' + o.name), ', ')
                                  FROM sys.sql_modules AS m
                                  INNER JOIN sys.objects AS o ON o.object_id = m.object_id
                                  INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
                                  WHERE o.is_ms_shipped = 0
                                    AND (o.name LIKE '%purge%' OR o.name LIKE '%archive%'
                                         OR o.name LIKE '%retention%'
                                         OR m.definition LIKE '%retention%' OR m.definition LIKE '%archive%')
                                    AND (m.definition LIKE @DeletePattern OR m.definition LIKE @TruncPattern
                                         OR m.definition LIKE @SwitchPattern)), 500), 'none');

    SELECT @PartitionSchemes = COUNT(*) FROM sys.partition_schemes;

    INSERT INTO @Big (ObjectId, TableName, PartCount)
    SELECT t.object_id,
           CONVERT(NVARCHAR(300), s.name + '.' + t.name),
           (SELECT COUNT(*) FROM sys.partitions AS p
            WHERE p.object_id = t.object_id AND p.index_id IN (0, 1))
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND ISNULL((SELECT SUM(ps.row_count) FROM sys.dm_db_partition_stats AS ps
                  WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)), 0) >= 1000000;

    SELECT @LargeTables  = COUNT(*),
           @LargeCovered = ISNULL(SUM(CASE WHEN PartCount > 1 THEN 1 ELSE 0 END), 0)
    FROM @Big;
END TRY
BEGIN CATCH
    SET @TableCount = -1;
END CATCH;

SET @Categories = CASE WHEN @PurgeModules > 0 THEN 1 ELSE 0 END
                + CASE WHEN @ArchiveTables > 0 THEN 1 ELSE 0 END
                + CASE WHEN @PartitionSchemes > 0 THEN 1 ELSE 0 END;

SET @Score = CASE
    WHEN @TableCount < 0 THEN 0
    WHEN @TableCount = 0 THEN 3
    WHEN @Categories = 0 THEN 0
    WHEN @Categories = 1 THEN 1
    WHEN @PurgeModules > 0 AND (@LargeTables = 0 OR @LargeCovered = @LargeTables) THEN 3
    ELSE 2
END;

SET @Finding = CASE
    WHEN @TableCount < 0 THEN CONCAT('Catalog metadata in ', @DatabaseQueried, ' could not be read, so archival and purge evidence was not collected.')
    WHEN @TableCount = 0 THEN CONCAT('No user tables found in ', @DatabaseQueried, '; there is no aged data requiring an archival or purge process.')
    ELSE CONCAT('In ', @DatabaseQueried, ': archive/history/retention tables = ', @ArchiveTables,
                ' (', @ArchiveList, '); purge or retention modules issuing row removal or partition switching = ',
                @PurgeModules, ' (', @PurgeList, '); partition schemes = ', @PartitionSchemes,
                '; tables over 1,000,000 rows = ', @LargeTables,
                ', of which partitioned = ', @LargeCovered, '.')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;

