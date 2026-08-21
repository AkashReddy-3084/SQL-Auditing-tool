-- Checklist: No stringly-typed dates/numbers; correct temporal types
-- Scope: DATABASE
-- Scoring: 3 = no suspect columns; 2 = < 5% of total columns; 1 = 5-25% of total columns; 0 = > 25% of total columns

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Sql = N'
    DECLARE @TotalCols INT;
    DECLARE @SuspectCols INT;
    DECLARE @SuspectList NVARCHAR(MAX);

    SELECT @TotalCols = COUNT(*) FROM sys.columns;

    SELECT @SuspectCols = COUNT(*), 
           @SuspectList = STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) + ''.'' + QUOTENAME(c.name), '', '')
    FROM sys.columns c
    JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    JOIN sys.types ty ON c.user_type_id = ty.user_type_id
    WHERE ty.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'')
    AND (
        c.name LIKE ''%date%'' OR c.name LIKE ''%time%'' OR 
        c.name LIKE ''%amount%'' OR c.name LIKE ''%price%'' OR 
        c.name LIKE ''%qty%'' OR c.name LIKE ''%count%''
    );

    SELECT 
        DB_NAME(),
        CASE 
            WHEN ISNULL(@SuspectCols, 0) = 0 THEN 3 
            WHEN CAST(ISNULL(@SuspectCols, 0) * 100.0 / NULLIF(@TotalCols, 0) AS FLOAT) < 5 THEN 2 
            WHEN CAST(ISNULL(@SuspectCols, 0) * 100.0 / NULLIF(@TotalCols, 0) AS FLOAT) < 25 THEN 1 
            ELSE 0 
        END,
        CASE 
            WHEN ISNULL(@SuspectCols, 0) = 0 THEN ''No suspect string-typed date/number columns found''
            ELSE ''Suspect columns: '' + @SuspectList 
        END;';
    
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    EXEC sp_executesql @Sql;
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
            SET @Sql = N'
            DECLARE @TotalCols INT;
            DECLARE @SuspectCols INT;
            DECLARE @SuspectList NVARCHAR(MAX);

            SELECT @TotalCols = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.columns;

            SELECT @SuspectCols = COUNT(*), 
                   @SuspectList = STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) + ''.'' + QUOTENAME(c.name), '', '')
            FROM ' + QUOTENAME(@DbName) + N'.sys.columns c
            JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id
            JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id
            JOIN ' + QUOTENAME(@DbName) + N'.sys.types ty ON c.user_type_id = ty.user_type_id
            WHERE ty.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'')
            AND (
                c.name LIKE ''%date%'' OR c.name LIKE ''%time%'' OR 
                c.name LIKE ''%amount%'' OR c.name LIKE ''%price%'' OR 
                c.name LIKE ''%qty%'' OR c.name LIKE ''%count%''
            );

            SELECT 
                @p_Db,
                CASE 
                    WHEN ISNULL(@SuspectCols, 0) = 0 THEN 3 
                    WHEN CAST(ISNULL(@SuspectCols, 0) * 100.0 / NULLIF(@TotalCols, 0) AS FLOAT) < 5 THEN 2 
                    WHEN CAST(ISNULL(@SuspectCols, 0) * 100.0 / NULLIF(@TotalCols, 0) AS FLOAT) < 25 THEN 1 
                    ELSE 0 
                END,
                CASE 
                    WHEN ISNULL(@SuspectCols, 0) = 0 THEN ''No suspect string-typed date/number columns found''
                    ELSE ''Suspect columns: '' + @SuspectList 
                END;';

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