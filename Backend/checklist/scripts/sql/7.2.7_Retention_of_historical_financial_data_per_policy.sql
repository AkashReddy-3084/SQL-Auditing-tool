-- Checklist: Retention of historical financial data per policy
-- Scope: DATABASE
-- Scoring: 0: No partitioning or archival tables found; 1: Limited evidence (1-5 partitioned/archive tables); 2: Good evidence (>5 partitioned/archive tables, indicating retention strategy; full policy compliance requires human review).
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalTables INT;
    DECLARE @PartitionedTables INT;
    DECLARE @ArchiveTables INT;
    DECLARE @PartitionedList NVARCHAR(MAX);
    DECLARE @ArchiveList NVARCHAR(MAX);

    SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';

    SELECT @PartitionedTables = COUNT(DISTINCT t.object_id),
           @PartitionedList = STRING_AGG(s.name + ''.'' + t.name, '', '')
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    JOIN sys.indexes i ON t.object_id = i.object_id
    JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
    WHERE i.type <= 1;

    SELECT @ArchiveTables = COUNT(*),
           @ArchiveList = STRING_AGG(s.name + ''.'' + t.name, '', '')
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.name LIKE ''%archive%'' OR t.name LIKE ''%history%'' OR t.name LIKE ''%retention%'';

    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '''';

    IF @PartitionedTables = 0 AND @ArchiveTables = 0
        SET @DbScore = 0;
    ELSE IF @PartitionedTables + @ArchiveTables <= 5
        SET @DbScore = 1;
    ELSE
        SET @DbScore = 2;

    SET @DbFinding = ''Total tables: '' + CAST(@TotalTables AS NVARCHAR(10)) + ''; Partitioned: '' + CAST(@PartitionedTables AS NVARCHAR(10)) + ''; Archive/History: '' + CAST(@ArchiveTables AS NVARCHAR(10)) + ''.'';
    IF @PartitionedTables > 0 SET @DbFinding = @DbFinding + '' Partitioned tables: '' + @PartitionedList + ''.'';
    IF @ArchiveTables > 0 SET @DbFinding = @DbFinding + '' Archive tables: '' + @ArchiveList + ''.'';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TotalTables INT;
            DECLARE @PartitionedTables INT;
            DECLARE @ArchiveTables INT;
            DECLARE @PartitionedList NVARCHAR(MAX);
            DECLARE @ArchiveList NVARCHAR(MAX);

            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';

            SELECT @PartitionedTables = COUNT(DISTINCT t.object_id),
                   @PartitionedList = STRING_AGG(s.name + ''.'' + t.name, '', '')
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            JOIN sys.indexes i ON t.object_id = i.object_id
            JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
            WHERE i.type <= 1;

            SELECT @ArchiveTables = COUNT(*),
                   @ArchiveList = STRING_AGG(s.name + ''.'' + t.name, '', '')
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.name LIKE ''%archive%'' OR t.name LIKE ''%history%'' OR t.name LIKE ''%retention%'';

            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = '''';

            IF @PartitionedTables = 0 AND @ArchiveTables = 0
                SET @DbScore = 0;
            ELSE IF @PartitionedTables + @ArchiveTables <= 5
                SET @DbScore = 1;
            ELSE
                SET @DbScore = 2;

            SET @DbFinding = ''Total tables: '' + CAST(@TotalTables AS NVARCHAR(10)) + ''; Partitioned: '' + CAST(@PartitionedTables AS NVARCHAR(10)) + ''; Archive/History: '' + CAST(@ArchiveTables AS NVARCHAR(10)) + ''.'';
            IF @PartitionedTables > 0 SET @DbFinding = @DbFinding + '' Partitioned tables: '' + @PartitionedList + ''.'';
            IF @ArchiveTables > 0 SET @DbFinding = @DbFinding + '' Archive tables: '' + @ArchiveList + ''.'';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;