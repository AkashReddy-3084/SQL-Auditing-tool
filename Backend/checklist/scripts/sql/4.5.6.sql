-- Checklist 4.5.6 - NOT NULL applied to mandatory columns
-- Read-only: catalog metadata only, no data or state is modified.
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(50) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = N'None';
DECLARE @Finding NVARCHAR(MAX) = N'Evaluation did not complete.';

DECLARE @IsAzureDb BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @TotalCols BIGINT = 0;
DECLARE @TotalViol BIGINT = 0;
DECLARE @DbList NVARCHAR(MAX) = N'';
DECLARE @Detail NVARCHAR(MAX) = N'';
DECLARE @DbName SYSNAME;
DECLARE @Prefix NVARCHAR(300);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @dbTotal BIGINT;
DECLARE @dbViol BIGINT;
DECLARE @Pct DECIMAL(9,4);

-- {P} is replaced by an empty string (Azure / current database) or by a QUOTENAME'd database prefix.
DECLARE @Core NVARCHAR(MAX) = N'SELECT @pTotal = COUNT(*),
       @pViol = SUM(CASE WHEN c.is_nullable = 1 AND c.is_computed = 0
                          AND (c.default_object_id <> 0
                               OR EXISTS (SELECT 1 FROM {P}sys.foreign_key_columns fkc
                                          WHERE fkc.parent_object_id = c.object_id
                                            AND fkc.parent_column_id = c.column_id)
                               OR EXISTS (SELECT 1 FROM {P}sys.index_columns ic
                                          INNER JOIN {P}sys.indexes i
                                                  ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                                          WHERE ic.object_id = c.object_id
                                            AND ic.column_id = c.column_id
                                            AND ic.is_included_column = 0
                                            AND i.is_unique = 1
                                            AND i.has_filter = 0)
                               OR c.name LIKE ''%Id''
                               OR c.name LIKE ''%Code''
                               OR c.name LIKE ''%Name''
                               OR c.name LIKE ''%Status'')
                         THEN 1 ELSE 0 END)
FROM {P}sys.columns c
INNER JOIN {P}sys.tables t ON t.object_id = c.object_id
INNER JOIN {P}sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0 AND t.type = ''U'' AND s.name <> ''sys'';';

IF @IsAzureDb = 1
BEGIN
    SET @DbName = DB_NAME();
    SET @dbTotal = 0;
    SET @dbViol = 0;
    SET @Sql = REPLACE(@Core, N'{P}', N'');
    EXEC sys.sp_executesql @Sql,
         N'@pTotal BIGINT OUTPUT, @pViol BIGINT OUTPUT',
         @pTotal = @dbTotal OUTPUT, @pViol = @dbViol OUTPUT;
    SET @dbTotal = ISNULL(@dbTotal, 0);
    SET @dbViol = ISNULL(@dbViol, 0);
    SET @TotalCols = @TotalCols + @dbTotal;
    SET @TotalViol = @TotalViol + @dbViol;
    SET @DbList = @DbName;
    IF @dbViol > 0
        SET @Detail = @DbName + N'=' + CAST(@dbViol AS NVARCHAR(20));
END
ELSE
BEGIN
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @DbName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Prefix = QUOTENAME(@DbName) + N'.';
        SET @dbTotal = 0;
        SET @dbViol = 0;
        SET @Sql = REPLACE(@Core, N'{P}', @Prefix);
        EXEC sys.sp_executesql @Sql,
             N'@pTotal BIGINT OUTPUT, @pViol BIGINT OUTPUT',
             @pTotal = @dbTotal OUTPUT, @pViol = @dbViol OUTPUT;
        SET @dbTotal = ISNULL(@dbTotal, 0);
        SET @dbViol = ISNULL(@dbViol, 0);
        SET @TotalCols = @TotalCols + @dbTotal;
        SET @TotalViol = @TotalViol + @dbViol;
        SET @DbList = CASE WHEN @DbList = N'' THEN @DbName ELSE @DbList + N', ' + @DbName END;
        IF @dbViol > 0
            SET @Detail = CASE WHEN @Detail = N'' THEN N'' ELSE @Detail + N'; ' END
                          + @DbName + N'=' + CAST(@dbViol AS NVARCHAR(20));
        FETCH NEXT FROM db_cur INTO @DbName;
    END
    CLOSE db_cur;
    DEALLOCATE db_cur;
END

SET @DatabaseQueried = ISNULL(NULLIF(@DbList, N''), N'None');

IF @TotalCols = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No user-defined table columns could be read on this instance, so NOT NULL usage on mandatory columns could not be assessed. Databases queried: ' + @DatabaseQueried + N'.';
END
ELSE
BEGIN
    SET @Pct = CAST(@TotalViol AS DECIMAL(19,4)) * 100.0 / CAST(@TotalCols AS DECIMAL(19,4));
    SET @Score = CASE
                    WHEN @TotalViol = 0 THEN 3
                    WHEN @Pct < 1.0 THEN 2
                    WHEN @Pct < 5.0 THEN 1
                    ELSE 0
                 END;
    SET @Finding = N'Examined ' + CAST(@TotalCols AS NVARCHAR(20)) + N' user table column(s); '
                 + CAST(@TotalViol AS NVARCHAR(20)) + N' ('
                 + CAST(CAST(@Pct AS DECIMAL(9,2)) AS NVARCHAR(20))
                 + N'%) are nullable despite structural evidence of being mandatory (DEFAULT constraint, unique index/constraint membership, foreign-key child column, or mandatory identifier naming). '
                 + CASE WHEN @Detail = N'' THEN N'No database reported a mandatory-but-nullable column.'
                        ELSE N'Per-database counts: ' + LEFT(@Detail, 700) + N'.' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SET @Finding = ISNULL(@Finding, N'No finding produced.');
SET @DatabaseQueried = ISNULL(@DatabaseQueried, N'None');

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;