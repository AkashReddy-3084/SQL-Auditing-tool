-- Checklist: Technical metadata (schema) captured and current
-- Scope: DATABASE
-- Scoring: 0=No metadata evidence, 1=Minimal evidence (<20% coverage or empty metadata table), 2=Good evidence (>20% coverage or populated metadata table), 3=Strong evidence (>60% coverage or comprehensive metadata table)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @TotalTables INT = (SELECT COUNT(*) FROM sys.tables WHERE type = ''U'');
        DECLARE @TablesWithProps INT = 0;
        DECLARE @TotalColumns INT = (SELECT COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.type = ''U'');
        DECLARE @ColsWithProps INT = 0;
        DECLARE @MetaTableExists INT = (SELECT COUNT(*) FROM sys.tables WHERE name LIKE ''%Metadata%'' OR name LIKE ''%DataDictionary%'' OR name LIKE ''%SchemaInfo%'');
        DECLARE @MetaTableRowCount INT = 0;

        SELECT @TablesWithProps = COUNT(DISTINCT major_id) FROM sys.extended_properties WHERE class = 1 AND minor_id = 0;
        SELECT @ColsWithProps = COUNT(*) FROM sys.extended_properties WHERE class = 1 AND minor_id > 0;

        IF @MetaTableExists > 0
        BEGIN
            SELECT @MetaTableRowCount = ISNULL(SUM(p.rows), 0)
            FROM sys.tables t
            JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id AND p.index_id IN (0, 1)
            WHERE t.name LIKE ''%Metadata%'' OR t.name LIKE ''%DataDictionary%'' OR t.name LIKE ''%SchemaInfo%'';
        END

        DECLARE @DbScore INT = 0;
        IF @TotalTables = 0 SET @DbScore = 3;
        ELSE
        BEGIN
            DECLARE @TablePropPct FLOAT = CAST(@TablesWithProps AS FLOAT) / NULLIF(@TotalTables, 0);
            DECLARE @ColPropPct FLOAT = CAST(@ColsWithProps AS FLOAT) / NULLIF(@TotalColumns, 0);
            DECLARE @MaxPct FLOAT = CASE WHEN @TablePropPct > @ColPropPct THEN @TablePropPct ELSE @ColPropPct END;

            IF @MaxPct >= 0.6 OR (@MetaTableExists > 0 AND @MetaTableRowCount > 100) SET @DbScore = 3;
            ELSE IF @MaxPct >= 0.2 OR (@MetaTableExists > 0 AND @MetaTableRowCount > 10) SET @DbScore = 2;
            ELSE IF @MaxPct > 0 OR @MetaTableExists > 0 SET @DbScore = 1;
            ELSE SET @DbScore = 0;
        END
        INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);
        ';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;