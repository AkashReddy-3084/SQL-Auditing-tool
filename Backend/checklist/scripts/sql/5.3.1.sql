DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    -- Azure SQL Database: Current database only
    DECLARE @TotalRows BIGINT = 0;
    DECLARE @OrphanRows BIGINT = 0;
    DECLARE @FKCount INT = 0;

    SELECT @FKCount = COUNT(*) FROM sys.foreign_keys;

    IF @FKCount > 0
    BEGIN
        -- We use a cursor to iterate through FKs to avoid massive JOINs and handle large datasets
        DECLARE fk_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT 
            QUOTENAME(s.name) + '.' + QUOTENAME(t.name), 
            QUOTENAME(c1.name), 
            QUOTENAME(s2.name) + '.' + QUOTENAME(t2.name), 
            QUOTENAME(c2.name)
        FROM sys.foreign_keys fk
        JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
        JOIN sys.tables t ON fk.parent_object_id = t.object_id
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        JOIN sys.columns c1 ON fkc.parent_object_id = c1.object_id AND fkc.parent_column_id = c1.column_id
        JOIN sys.tables t2 ON fk.referenced_object_id = t2.object_id
        JOIN sys.schemas s2 ON t2.schema_id = s2.schema_id
        JOIN sys.columns c2 ON fkc.referenced_object_id = c2.object_id AND fkc.referenced_column_id = c2.column_id;

        OPEN fk_cursor;
        DECLARE @ParentTable NVARCHAR(256), @ParentCol NVARCHAR(128), @RefTable NVARCHAR(256), @RefCol NVARCHAR(128);
        FETCH NEXT FROM fk_cursor INTO @ParentTable, @ParentCol, @RefTable, @RefCol;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @CountSql NVARCHAR(MAX) = N'SELECT @p_Total = COUNT(*), @p_Orphans = COUNT(*) FROM ' + @ParentTable + ' WHERE ' + @ParentCol + ' IS NOT NULL';
            EXEC sp_executesql @CountSql, N'@p_Total BIGINT OUTPUT, @p_Orphans BIGINT OUTPUT', @p_Total = @TotalRows OUTPUT, @p_Orphans = @OrphanRows OUTPUT;
            
            -- This is a simplification for the total; we accumulate
            -- In a real scenario, we'd sum all rows across all FKs
            -- But for the sake of the audit, we check the existence of orphans
            DECLARE @OrphanCheckSql NVARCHAR(MAX) = N'SELECT COUNT(*) FROM ' + @ParentTable + ' WHERE ' + @ParentCol + ' IS NOT NULL AND ' + @ParentCol + ' NOT IN (SELECT ' + @RefCol + ' FROM ' + @RefTable + ')';
            DECLARE @CurrentOrphans BIGINT = 0;
            EXEC sp_executesql @OrphanCheckSql, N'@p_Orphans BIGINT OUTPUT', @p_Orphans = @CurrentOrphans OUTPUT;
            
            SET @OrphanRows = @OrphanRows + @CurrentOrphans;
            
            -- To calculate percentage, we need total rows of the parent table
            DECLARE @TotalTableRows BIGINT = 0;
            DECLARE @TotalSql NVARCHAR(MAX) = N'SELECT COUNT(*) FROM ' + @ParentTable;
            EXEC sp_executesql @TotalSql, N'@p_Total BIGINT OUTPUT', @p_Total = @TotalTableRows OUTPUT;
            
            SET @TotalRows = @TotalRows + @TotalTableRows;

            FETCH NEXT FROM fk_cursor INTO @ParentTable, @ParentCol, @RefTable, @RefCol;
        END
        CLOSE fk_cursor;
        DEALLOCATE fk_cursor;
    END

    DECLARE @Pct FLOAT = CASE WHEN @TotalRows = 0 THEN 0 ELSE (CAST(@OrphanRows AS FLOAT) / CAST(@TotalRows AS FLOAT)) * 100 END;
    
    DECLARE @DbScore INT = CASE 
        WHEN @OrphanRows = 0 THEN 3 
        WHEN @Pct < 1 THEN 2 
        WHEN @Pct <= 5 THEN 1 
        ELSE 0 END;
    
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (DB_NAME(), @DbScore, 'Orphaned rows: ' + CAST(@OrphanRows AS NVARCHAR(20)) + ' (' + CAST(ROUND(@Pct, 2) AS NVARCHAR(10)) + '%)');
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
            DECLARE @DbTotal BIGINT = 0;
            DECLARE @DbOrphans BIGINT = 0;
            DECLARE @DbFKCount INT = 0;

            -- Get FK count for this DB
            DECLARE @FKCountSql NVARCHAR(MAX) = N'SELECT @p_Count = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys';
            EXEC sp_executesql @FKCountSql, N'@p_Count INT OUTPUT', @p_Count = @DbFKCount OUTPUT;

            IF @DbFKCount > 0
            BEGIN
                -- Use a temp table to store FK details for the specific DB
                CREATE TABLE #FKs (ParentTable NVARCHAR(256), ParentCol NVARCHAR(128), RefTable NVARCHAR(256), RefCol NVARCHAR(128));
                SET @Sql = N'INSERT INTO #FKs SELECT 
                    QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name), 
                    QUOTENAME(c1.name), 
                    QUOTENAME(s2.name) + ''.'' + QUOTENAME(t2.name), 
                    QUOTENAME(c2.name)
                FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys fk
                JOIN ' + QUOTENAME(@DbName) + N'.sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON fk.parent_object_id = t.object_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.columns c1 ON fkc.parent_object_id = c1.object_id AND fkc.parent_column_id = c1.column_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t2 ON fk.referenced_object_id = t2.object_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s2 ON t2.schema_id = s2.schema_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.columns c2 ON fkc.referenced_object_id = c2.object_id AND fkc.referenced_column_id = c2.column_id';
                EXEC sp_executesql @Sql;

                DECLARE @CurParentTable NVARCHAR(256), @CurParentCol NVARCHAR(128), @CurRefTable NVARCHAR(256), @CurRefCol NVARCHAR(128);
                DECLARE fk_db_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT * FROM #FKs;
                OPEN fk_db_cursor;
                FETCH NEXT FROM fk_db_cursor INTO @CurParentTable, @CurParentCol, @CurRefTable, @CurRefCol;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    DECLARE @RowSql NVARCHAR(MAX) = N'SELECT @p_Total = COUNT(*) FROM ' + @CurParentTable + ' WHERE ' + @CurParentCol + ' IS NOT NULL';
                    DECLARE @TRows BIGINT = 0;
                    EXEC sp_executesql @RowSql, N'@p_Total BIGINT OUTPUT', @p_Total = @TRows OUTPUT;
                    SET @DbTotal = @DbTotal + @TRows;

                    DECLARE @OrphanSql NVARCHAR(MAX) = N'SELECT COUNT(*) FROM ' + @CurParentTable + ' WHERE ' + @CurParentCol + ' IS NOT NULL AND ' + @CurParentCol + ' NOT IN (SELECT ' + @CurRefCol + ' FROM ' + @CurRefTable + ')';
                    DECLARE @ORows BIGINT = 0;
                    EXEC sp_executesql @OrphanSql, N'@p_Orphans BIGINT OUTPUT', @p_Orphans = @ORows OUTPUT;
                    SET @DbOrphans = @DbOrphans + @ORows;

                    FETCH NEXT FROM fk_db_cursor INTO @CurParentTable, @CurParentCol, @CurRefTable, @CurRefCol;
                END
                CLOSE fk_db_cursor;
                DEALLOCATE fk_db_cursor;
                DROP TABLE #FKs;
            END

            DECLARE @DbPct FLOAT = CASE WHEN @DbTotal = 0 THEN 0 ELSE (CAST(@DbOrphans AS FLOAT) / CAST(@DbTotal AS FLOAT)) * 100 END;
            DECLARE @DbScoreFinal INT = CASE 
                WHEN @DbOrphans = 0 THEN 3 
                WHEN @DbPct < 1 THEN 2 
                WHEN @DbPct <= 5 THEN 1 
                ELSE 0 END;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, @DbScoreFinal, 'Orphaned rows: ' + CAST(@DbOrphans AS NVARCHAR(20)) + ' (' + CAST(ROUND(@DbPct, 2) AS NVARCHAR(10)) + '%)');
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