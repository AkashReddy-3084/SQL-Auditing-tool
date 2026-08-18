-- Checklist: Dynamic Data Masking applied to sensitive columns where appropriate
-- Scope: DATABASE
-- Scoring: 0 = No masked columns found; 1 = N/A; 2 = Masked columns found (automated check caps at 2 as full compliance requires human review of sensitive data coverage); 3 = N/A
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    BEGIN TRY
        SET @Sql = N'
        DECLARE @MaskedCount INT;
        DECLARE @MaskedColumns NVARCHAR(MAX);
        SELECT @MaskedCount = COUNT(*)
        FROM sys.masked_columns mc
        JOIN sys.columns c ON mc.object_id = c.object_id AND mc.column_id = c.column_id
        JOIN sys.tables t ON c.object_id = t.object_id
        JOIN sys.schemas s ON t.schema_id = s.schema_id;

        SELECT @MaskedColumns = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
        FROM sys.masked_columns mc
        JOIN sys.columns c ON mc.object_id = c.object_id AND mc.column_id = c.column_id
        JOIN sys.tables t ON c.object_id = t.object_id
        JOIN sys.schemas s ON t.schema_id = s.schema_id;

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@pDbName, 
                CASE WHEN @MaskedCount > 0 THEN 2 ELSE 0 END,
                CASE WHEN @MaskedCount > 0 THEN ''Masked columns: '' + @MaskedColumns ELSE ''No masked columns found'' END);
        ';
        EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @MaskedCount INT;
            DECLARE @MaskedColumns NVARCHAR(MAX);
            SELECT @MaskedCount = COUNT(*)
            FROM sys.masked_columns mc
            JOIN sys.columns c ON mc.object_id = c.object_id AND mc.column_id = c.column_id
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id;

            SELECT @MaskedColumns = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
            FROM sys.masked_columns mc
            JOIN sys.columns c ON mc.object_id = c.object_id AND mc.column_id = c.column_id
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@pDbName, 
                    CASE WHEN @MaskedCount > 0 THEN 2 ELSE 0 END,
                    CASE WHEN @MaskedCount > 0 THEN ''Masked columns: '' + @MaskedColumns ELSE ''No masked columns found'' END);
            ';
            EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
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

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;