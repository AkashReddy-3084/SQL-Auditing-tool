-- Checklist: Fact tables contain only foreign keys and measures (no descriptive attributes)
-- Scope: DATABASE
-- Scoring: 3 = no descriptive columns; 2 = < 5% descriptive; 1 = 5-25% descriptive; 0 = > 25% descriptive

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT 
        DB_NAME(),
        CASE 
            WHEN SUM(DescriptiveCount) = 0 THEN 3 
            WHEN CAST(SUM(DescriptiveCount) * 100.0 / NULLIF(SUM(TotalCols), 0) AS FLOAT) < 5 THEN 2 
            WHEN CAST(SUM(DescriptiveCount) * 100.0 / NULLIF(SUM(TotalCols), 0) AS FLOAT) < 25 THEN 1 
            ELSE 0 
        END,
        CASE 
            WHEN SUM(DescriptiveCount) = 0 THEN 'No descriptive columns found in fact tables'
            ELSE 'Descriptive columns: ' + (SELECT STRING_AGG(ColDetail, ', ') FROM (
                SELECT QUOTENAME(s.name) + '.' + QUOTENAME(t.name) + '(' + c.name + ')' as ColDetail
                FROM sys.tables t
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                JOIN sys.columns c ON t.object_id = c.object_id
                LEFT JOIN sys.foreign_key_columns fkc ON fkc.parent_object_id = t.object_id AND fkc.parent_column_id = c.column_id
                JOIN sys.types ty ON c.user_type_id = ty.user_type_id
                WHERE (t.name LIKE 'Fact%' OR t.name LIKE '%Fact')
                  AND fkc.parent_column_id IS NULL
                  AND ty.name NOT IN ('int', 'bigint', 'smallint', 'tinyint', 'decimal', 'numeric', 'float', 'real', 'money', 'smallmoney', 'datetime', 'datetime2', 'date', 'datetimeoffset')
            ) AS Details)
        END
    FROM (
        SELECT 
            t.object_id,
            COUNT(*) as TotalCols,
            SUM(CASE WHEN fkc.parent_column_id IS NULL AND ty.name NOT IN ('int', 'bigint', 'smallint', 'tinyint', 'decimal', 'numeric', 'float', 'real', 'money', 'smallmoney', 'datetime', 'datetime2', 'date', 'datetimeoffset') THEN 1 ELSE 0 END) as DescriptiveCount
        FROM sys.tables t
        JOIN sys.columns c ON t.object_id = c.object_id
        JOIN sys.types ty ON c.user_type_id = ty.user_type_id
        LEFT JOIN sys.foreign_key_columns fkc ON fkc.parent_object_id = t.object_id AND fkc.parent_column_id = c.column_id
        WHERE (t.name LIKE 'Fact%' OR t.name LIKE '%Fact')
        GROUP BY t.object_id
    ) AS FactStats;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT 
                @p_Db,
                CASE 
                    WHEN SUM(DescriptiveCount) = 0 THEN 3 
                    WHEN CAST(SUM(DescriptiveCount) * 100.0 / NULLIF(SUM(TotalCols), 0) AS FLOAT) < 5 THEN 2 
                    WHEN CAST(SUM(DescriptiveCount) * 100.0 / NULLIF(SUM(TotalCols), 0) AS FLOAT) < 25 THEN 1 
                    ELSE 0 
                END,
                CASE 
                    WHEN SUM(DescriptiveCount) = 0 THEN ''No descriptive columns found in fact tables''
                    ELSE ''Descriptive columns: '' + (SELECT STRING_AGG(ColDetail, '', '') FROM (
                        SELECT QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) + ''('' + c.name + '')'' as ColDetail
                        FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.columns c ON t.object_id = c.object_id
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.types ty ON c.user_type_id = ty.user_type_id
                        LEFT JOIN ' + QUOTENAME(@DbName) + N'.sys.foreign_key_columns fkc ON fkc.parent_object_id = t.object_id AND fkc.parent_column_id = c.column_id
                        WHERE (t.name LIKE ''Fact%'' OR t.name LIKE ''%Fact'')
                          AND fkc.parent_column_id IS NULL
                          AND ty.name NOT IN (''int'', ''bigint'', ''smallint'', ''tinyint'', ''decimal'', ''numeric'', ''float'', ''real'', ''money'', ''smallmoney'', ''datetime'', ''datetime2'', ''date'', ''datetimeoffset'')
                    ) AS Details)
                END
                FROM (
                    SELECT 
                        t.object_id,
                        COUNT(*) as TotalCols,
                        SUM(CASE WHEN fkc.parent_column_id IS NULL AND ty.name NOT IN (''int'', ''bigint'', ''smallint'', ''tinyint'', ''decimal'', ''numeric'', ''float'', ''real'', ''money'', ''smallmoney'', ''datetime'', ''datetime2'', ''date'', ''datetimeoffset'') THEN 1 ELSE 0 END) as DescriptiveCount
                    FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
                    JOIN ' + QUOTENAME(@DbName) + N'.sys.columns c ON t.object_id = c.object_id
                    JOIN ' + QUOTENAME(@DbName) + N'.sys.types ty ON c.user_type_id = ty.user_type_id
                    LEFT JOIN ' + QUOTENAME(@DbName) + N'.sys.foreign_key_columns fkc ON fkc.parent_object_id = t.object_id AND fkc.parent_column_id = c.column_id
                    WHERE (t.name LIKE ''Fact%'' OR t.name LIKE ''%Fact'')
                    GROUP BY t.object_id
                ) AS FactStats;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Evaluation failed: ' + ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;