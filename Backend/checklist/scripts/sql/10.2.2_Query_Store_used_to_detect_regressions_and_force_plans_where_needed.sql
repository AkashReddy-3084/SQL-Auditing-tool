-- Checklist: Query Store used to detect regressions and force plans where needed
-- Scope: DATABASE
-- Scoring: 0=Disabled, 1=Enabled but no forced plans, 2=Enabled + forced plans but manual/none capture, 3=Enabled + forced plans + auto/custom capture

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
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

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT 
        ''' + @DbName + ''' AS DbName,
        CASE 
            WHEN qso.actual_state <> 2 THEN 0
            WHEN qp.ForcedCount = 0 THEN 1
            WHEN qso.query_capture_mode IN (0, 4) THEN 2
            ELSE 3
        END AS DbScore,
        CASE 
            WHEN qso.actual_state <> 2 THEN ''''Query Store disabled (actual_state=''' + CAST(qso.actual_state AS NVARCHAR(10)) + ''')''''
            WHEN qp.ForcedCount = 0 THEN ''''Query Store enabled, but no forced plans found''''
            WHEN qso.query_capture_mode IN (0, 4) THEN ''''Query Store enabled, '''' + CAST(qp.ForcedCount AS NVARCHAR(10)) + '''' forced plan(s) found, but capture mode is '''' + CASE qso.query_capture_mode WHEN 0 THEN ''''NONE'''' WHEN 4 THEN ''''MANUAL'''' END + ''''''''
            ELSE ''''Query Store enabled, '''' + CAST(qp.ForcedCount AS NVARCHAR(10)) + '''' forced plan(s) found, capture mode is '''' + CASE qso.query_capture_mode WHEN 1 THEN ''''ALL'''' WHEN 2 THEN ''''AUTO'''' WHEN 3 THEN ''''CUSTOM'''' END + ''''''''
        END AS Finding
    FROM sys.database_query_store_options qso
    CROSS APPLY (
        SELECT COUNT(*) AS ForcedCount
        FROM sys.query_store_plan
        WHERE is_forced_plan = 1
    ) qp;
    ';
    EXEC sp_executesql @Sql;
    SET @DatabaseQueried = @DbName;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
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
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT 
                ''' + @DbName + ''' AS DbName,
                CASE 
                    WHEN qso.actual_state <> 2 THEN 0
                    WHEN qp.ForcedCount = 0 THEN 1
                    WHEN qso.query_capture_mode IN (0, 4) THEN 2
                    ELSE 3
                END AS DbScore,
                CASE 
                    WHEN qso.actual_state <> 2 THEN ''''Query Store disabled (actual_state=''' + CAST(qso.actual_state AS NVARCHAR(10)) + ''')''''
                    WHEN qp.ForcedCount = 0 THEN ''''Query Store enabled, but no forced plans found''''
                    WHEN qso.query_capture_mode IN (0, 4) THEN ''''Query Store enabled, '''' + CAST(qp.ForcedCount AS NVARCHAR(10)) + '''' forced plan(s) found, but capture mode is '''' + CASE qso.query_capture_mode WHEN 0 THEN ''''NONE'''' WHEN 4 THEN ''''MANUAL'''' END + ''''''''
                    ELSE ''''Query Store enabled, '''' + CAST(qp.ForcedCount AS NVARCHAR(10)) + '''' forced plan(s) found, capture mode is '''' + CASE qso.query_capture_mode WHEN 1 THEN ''''ALL'''' WHEN 2 THEN ''''AUTO'''' WHEN 3 THEN ''''CUSTOM'''' END + ''''''''
                END AS Finding
            FROM sys.database_query_store_options qso
            CROSS APPLY (
                SELECT COUNT(*) AS ForcedCount
                FROM sys.query_store_plan
                WHERE is_forced_plan = 1
            ) qp;
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

    SET @DatabaseQueried = (
        SELECT STRING_AGG(DbName, ', ')
        FROM #DbResults
    );
END

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