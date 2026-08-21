-- Checklist: Partitioning strategy defined for large tables (by date/range) where beneficial
-- Scope: DATABASE
-- Scoring: 0: Large tables exist but none are partitioned by range. 1: Some large tables are partitioned by range. 2: Majority of large tables are partitioned by range. 3: All large tables (>1M rows) are partitioned by range, or no large tables exist.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
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

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    SET NOCOUNT ON;
    DECLARE @LargeThreshold INT = 1000000;
    DECLARE @LargeTables TABLE (TableName NVARCHAR(256), RowCount BIGINT, IsRangePartitioned BIT);
    INSERT INTO @LargeTables
    SELECT 
        QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name),
        SUM(ps.row_count),
        CASE WHEN pf.type = ''R'' THEN 1 ELSE 0 END
    FROM sys.tables t
    JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id < 2
    JOIN sys.dm_db_partition_stats ps ON i.object_id = ps.object_id AND i.index_id = ps.index_id
    LEFT JOIN sys.partition_schemes pscheme ON i.data_space_id = pscheme.data_space_id
    LEFT JOIN sys.partition_functions pf ON pscheme.function_id = pf.function_id
    GROUP BY t.object_id, t.schema_id, t.name, pf.type
    HAVING SUM(ps.row_count) >= @LargeThreshold;

    DECLARE @TotalLarge INT = (SELECT COUNT(*) FROM @LargeTables);
    DECLARE @PartitionedRange INT = (SELECT COUNT(*) FROM @LargeTables WHERE IsRangePartitioned = 1);
    DECLARE @NonCompliant NVARCHAR(MAX) = (SELECT STRING_AGG(TableName, ''', ''') FROM @LargeTables WHERE IsRangePartitioned = 0);
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    IF @TotalLarge = 0
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''No large tables (>1M rows) found.'';
    END
    ELSE IF @PartitionedRange = @TotalLarge
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''All large tables are partitioned by range.'';
    END
    ELSE IF @PartitionedRange >= @TotalLarge * 0.5
    BEGIN
        SET @DbScore = 2;
        SET @DbFinding = ''Most large tables are partitioned by range. Non-compliant: '' + ISNULL(@NonCompliant, ''None'');
    END
    ELSE IF @PartitionedRange > 0
    BEGIN
        SET @DbScore = 1;
        SET @DbFinding = ''Some large tables are partitioned by range. Non-compliant: '' + ISNULL(@NonCompliant, ''None'');
    END
    ELSE
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''Large tables exist but none are partitioned by range. Non-compliant: '' + ISNULL(@NonCompliant, ''None'');
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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
            SET NOCOUNT ON;
            DECLARE @LargeThreshold INT = 1000000;
            DECLARE @LargeTables TABLE (TableName NVARCHAR(256), RowCount BIGINT, IsRangePartitioned BIT);
            INSERT INTO @LargeTables
            SELECT 
                QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name),
                SUM(ps.row_count),
                CASE WHEN pf.type = ''R'' THEN 1 ELSE 0 END
            FROM sys.tables t
            JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id < 2
            JOIN sys.dm_db_partition_stats ps ON i.object_id = ps.object_id AND i.index_id = ps.index_id
            LEFT JOIN sys.partition_schemes pscheme ON i.data_space_id = pscheme.data_space_id
            LEFT JOIN sys.partition_functions pf ON pscheme.function_id = pf.function_id
            GROUP BY t.object_id, t.schema_id, t.name, pf.type
            HAVING SUM(ps.row_count) >= @LargeThreshold;

            DECLARE @TotalLarge INT = (SELECT COUNT(*) FROM @LargeTables);
            DECLARE @PartitionedRange INT = (SELECT COUNT(*) FROM @LargeTables WHERE IsRangePartitioned = 1);
            DECLARE @NonCompliant NVARCHAR(MAX) = (SELECT STRING_AGG(TableName, ''', ''') FROM @LargeTables WHERE IsRangePartitioned = 0);
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @TotalLarge = 0
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''No large tables (>1M rows) found.'';
            END
            ELSE IF @PartitionedRange = @TotalLarge
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''All large tables are partitioned by range.'';
            END
            ELSE IF @PartitionedRange >= @TotalLarge * 0.5
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''Most large tables are partition