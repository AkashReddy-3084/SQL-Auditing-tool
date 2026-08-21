-- Checklist: DQ KPIs defined: completeness, accuracy, timeliness, consistency, uniqueness, validity
-- Scope: DATABASE
-- Scoring: 0: None of the 6 KPIs found. 1: 1-2 KPIs found. 2: 3-5 KPIs found. 3: All 6 KPIs found.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    SET @DatabaseQueried = @DbName;
    
    BEGIN TRY
        SET @Sql = N'
        DECLARE @Kpis TABLE (KpiName NVARCHAR(50));
        INSERT INTO @Kpis VALUES (''completeness''), (''accuracy''), (''timeliness''), (''consistency''), (''uniqueness''), (''validity'');
        
        DECLARE @FoundKpis NVARCHAR(MAX) = '';
        DECLARE @Count INT = 0;
        
        SELECT @FoundKpis = STRING_AGG(k.KpiName, '',''), @Count = COUNT(*)
        FROM @Kpis k
        WHERE EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE LOWER(CONVERT(NVARCHAR(MAX), ep.value)) LIKE ''%'' + LOWER(k.KpiName) + ''%'')
           OR EXISTS (SELECT 1 FROM sys.tables t WHERE LOWER(t.name) LIKE ''%'' + LOWER(k.KpiName) + ''%'')
           OR EXISTS (SELECT 1 FROM sys.columns c WHERE LOWER(c.name) LIKE ''%'' + LOWER(k.KpiName) + ''%'')
           OR EXISTS (SELECT 1 FROM sys.procedures p WHERE LOWER(p.name) LIKE ''%'' + LOWER(k.KpiName) + ''%'')
           OR EXISTS (SELECT 1 FROM sys.views v WHERE LOWER(v.name) LIKE ''%'' + LOWER(k.KpiName) + ''%'');
        
        DECLARE @DbScore INT = CASE 
            WHEN @Count = 0 THEN 0
            WHEN @Count <= 2 THEN 1
            WHEN @Count <= 5 THEN 2
            ELSE 3
        END;
        
        DECLARE @DbFinding NVARCHAR(MAX) = CASE 
            WHEN @Count = 0 THEN ''No DQ KPIs found''
            ELSE ''Found '' + CAST(@Count AS NVARCHAR(10)) + '' KPI(s): '' + @FoundKpis
        END;
        
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@pDbName, @DbScore, @DbFinding);
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
            DECLARE @Kpis TABLE (KpiName NVARCHAR(50));
            INSERT INTO @Kpis VALUES (''completeness''), (''accuracy''), (''timeliness''), (''consistency''), (''uniqueness''), (''validity'');
            
            DECLARE @FoundKpis NVARCHAR(MAX) = '';
            DECLARE @Count INT = 0;
            
            SELECT @FoundKpis = STRING_AGG(k.KpiName, '',''), @Count = COUNT(*)
            FROM @Kpis k
            WHERE EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE LOWER(CONVERT(NVARCHAR(MAX), ep.value)) LIKE ''%'' + LOWER(k.KpiName) + ''%'')
               OR EXISTS (SELECT 1 FROM sys.tables t WHERE LOWER(t.name) LIKE ''%'' + LOWER(k.KpiName) + ''%'')
               OR EXISTS (SELECT 1 FROM sys.columns c WHERE LOWER(c.name) LIKE ''%'' + LOWER(k.KpiName) + ''%'')
               OR EXISTS (SELECT 1 FROM sys.procedures p WHERE LOWER(p.name) LIKE ''%'' + LOWER(k.KpiName) + ''%'')
               OR EXISTS (SELECT 1 FROM sys.views v WHERE LOWER(v.name) LIKE ''%'' + LOWER(k.KpiName) + ''%'');
            
            DECLARE @DbScore INT = CASE 
                WHEN @Count = 0 THEN 0
                WHEN @Count <= 2 THEN 1
                WHEN @Count <= 5 THEN 2
                ELSE 3
            END;
            
            DECLARE @DbFinding NVARCHAR(MAX) = CASE 
                WHEN @Count = 0 THEN ''No DQ KPIs found''
                ELSE ''Found '' + CAST(@Count AS NVARCHAR(10)) + '' KPI(s): '' + @FoundKpis
            END;
            
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@pDbName, @DbScore, @DbFinding);
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

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @Finding = ISNULL((
    SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
    FROM #DbResults
    WHERE Finding IS NOT NULL AND Finding <> ''
), 'No non-compliant findings found');

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;