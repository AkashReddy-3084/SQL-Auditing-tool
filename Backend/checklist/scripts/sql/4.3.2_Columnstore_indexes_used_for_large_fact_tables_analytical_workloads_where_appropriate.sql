-- Checklist: Columnstore indexes used for large fact tables / analytical workloads where appropriate
-- Scope: DATABASE
-- Scoring: 
-- 3: All large tables (>100k rows) have a columnstore index, or no large tables exist.
-- 2: >= 75% of large tables have a columnstore index.
-- 1: >= 1 large table has a columnstore index, but < 75%.
-- 0: Large tables exist, but none have a columnstore index.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @IsAzureSQL BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQL = 1
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
DECLARE @TotalLarge INT = 0;
DECLARE @CsCount INT = 0;
DECLARE @FindingText NVARCHAR(MAX) = '''';

SELECT @TotalLarge = COUNT(*), @CsCount = SUM(HasColumnstore)
FROM (
    SELECT 
        t.name AS TableName,
        SUM(p.row_count) AS RowCount,
        MAX(CASE WHEN i.type IN (5, 6) THEN 1 ELSE 0 END) AS HasColumnstore
    FROM sys.tables t
    JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id AND p.index_id < 2
    LEFT JOIN sys.indexes i ON t.object_id = i.object_id AND i.type IN (5, 6)
    GROUP BY t.name
    HAVING SUM(p.row_count) > 100000
) AS LargeTables;

SELECT @FindingText = STRING_AGG(TableName + '' ('' + CAST(RowCount AS NVARCHAR) + '' rows, '' + CASE WHEN HasColumnstore = 1 THEN ''CS'' ELSE ''No CS'' END + '')'', '', '')
FROM (
    SELECT 
        t.name AS TableName,
        SUM(p.row_count) AS RowCount,
        MAX(CASE WHEN i.type IN (5, 6) THEN 1 ELSE 0 END) AS HasColumnstore
    FROM sys.tables t
    JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id AND p.index_id < 2
    LEFT JOIN sys.indexes i ON t.object_id = i.object_id AND i.type IN (5, 6)
    GROUP BY t.name
    HAVING SUM(p.row_count) > 100000
) AS LargeTables;

IF @TotalLarge = 0
    SET @FindingText = ''No large tables (>100k rows) found'';

DECLARE @DbScore INT;
IF @TotalLarge = 0
    SET @DbScore = 3;
ELSE IF CAST(@CsCount AS FLOAT) / @TotalLarge >= 1.0
    SET @DbScore = 3;
ELSE IF CAST(@CsCount AS FLOAT) / @TotalLarge >= 0.75
    SET @DbScore = 2;
ELSE IF @CsCount > 0
    SET @DbScore = 1;
ELSE
    SET @DbScore = 0;

INSERT INTO #DbResults (DbName, DbScore, Finding)
VALUES ('' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @FindingText);';
    EXEC(@Sql);
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @