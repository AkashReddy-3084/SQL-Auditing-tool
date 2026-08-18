-- Checklist: Source-to-target reconciliation exists for financial data
-- Scope: DATABASE
-- Scoring: 3=Explicit reconciliation objects found; 2=Financial/ETL objects with reconciliation keywords; 1=Weak/partial evidence; 0=No evidence

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
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
    DECLARE @ReconcileCount INT = 0;
    DECLARE @FinancialCount INT = 0;
    DECLARE @Evidence NVARCHAR(MAX) = '''';
    DECLARE @DbNameParam NVARCHAR(128) = ''' + REPLACE(@DbName, '''', '''''') + N''';

    SELECT @ReconcileCount = COUNT(*) FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE p.is_ms_shipped = 0
      AND (p.name LIKE ''%reconcil%'' OR p.name LIKE ''%balance%'' OR m.definition LIKE ''%reconcil%'' OR m.definition LIKE ''%balance%'');

    SELECT @FinancialCount = COUNT(*) FROM sys.procedures p
    WHERE p.is_ms_shipped = 0
      AND (p.name LIKE ''%financial%'' OR p.name LIKE ''%source%target%'' OR p.name LIKE ''%control%total%'');

    SELECT @Evidence = STRING_AGG(p.name, '', '') FROM sys.procedures p 
    WHERE p.is_ms_shipped = 0 AND (p.name LIKE ''%reconcil%'' OR p.name LIKE ''%balance%'' OR p.name LIKE ''%financial%'');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        @DbNameParam,
        CASE WHEN @ReconcileCount > 0 THEN 3 WHEN @FinancialCount > 0 THEN 2 ELSE 0 END,
        CASE WHEN @Evidence IS NOT NULL THEN @Evidence ELSE ''No reconciliation or financial control objects found'' END
    );
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
            DECLARE @ReconcileCount INT = 0;
            DECLARE @FinancialCount INT = 0;
            DECLARE @Evidence NVARCHAR(MAX) = '''';
            DECLARE @DbNameParam NVARCHAR(128) = ''' + REPLACE(@DbName, '''', '''''') + N''';

            SELECT @ReconcileCount = COUNT(*) FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE p.is_ms_shipped = 0
              AND (p.name LIKE ''%reconcil%'' OR p.name LIKE ''%balance%'' OR m.definition LIKE ''%reconcil%'' OR m.definition LIKE ''%balance%'');

            SELECT @FinancialCount = COUNT(*) FROM sys.procedures p
            WHERE p.is_ms_shipped = 0
              AND (p.name LIKE ''%financial%'' OR p.name LIKE ''%source%target%'' OR p.name LIKE ''%control%total%'');

            SELECT @Evidence = STRING_AGG(p.name, '', '') FROM sys.procedures p 
            WHERE p.is_ms_shipped = 0 AND (p.name LIKE ''%reconcil%'' OR p.name LIKE ''%balance%'' OR p.name LIKE ''%financial%'');

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                @DbNameParam,
                CASE WHEN @ReconcileCount > 0 THEN 3 WHEN @FinancialCount > 0 THEN 2 ELSE 0 END,
                CASE WHEN @Evidence IS NOT NULL THEN @Evidence ELSE ''No reconciliation or financial control objects found'' END
            );
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

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;