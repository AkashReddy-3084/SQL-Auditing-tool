-- Checklist: Business rules for transformations documented outside code
-- Scope: DATABASE
-- Scoring: 0: No extended properties found. 1: <50% of objects documented. 2: >=50% documented (proxy evidence; full compliance requires human review). 3: Not applicable for documentation checks.

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

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalObjects INT;
    DECLARE @DocObjects INT;
    SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'', ''P'') AND is_ms_shipped = 0;
    SELECT @DocObjects = COUNT(DISTINCT o.object_id) FROM sys.objects o
    INNER JOIN sys.extended_properties ep ON o.object_id = ep.major_id AND ep.minor_id = 0
    WHERE o.type IN (''U'', ''P'') AND o.is_ms_shipped = 0;
    
    DECLARE @DbScore INT = 0;
    DECLARE @Finding NVARCHAR(MAX) = ''No documentation metadata found'';
    
    IF @TotalObjects > 0
    BEGIN
        DECLARE @Pct FLOAT = CAST(@DocObjects AS FLOAT) / @TotalObjects * 100;
        IF @Pct >= 50 SET @DbScore = 2;
        ELSE IF @Pct > 0 SET @DbScore = 1;
        SET @Finding = CAST(@DocObjects AS NVARCHAR) + '' of '' + CAST(@TotalObjects AS NVARCHAR) + '' objects have extended properties ('' + CAST(@Pct AS NVARCHAR(5)) + ''%)'';
    END
    
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@p_DbName, @DbScore, @Finding);
    ';
    EXEC sp_executesql @Sql, N'@p_DbName NVARCHAR(128)', @p_DbName = @DbName;
END
ELSE -- SQL Server / Azure SQL MI
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TotalObjects INT;
            DECLARE @DocObjects INT;
            SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'', ''P'') AND is_ms_shipped = 0;
            SELECT @DocObjects = COUNT(DISTINCT o.object_id) FROM sys.objects o
            INNER JOIN sys.extended_properties ep ON o.object_id = ep.major_id AND ep.minor_id = 0
            WHERE o.type IN (''U'', ''P'') AND o.is_ms_shipped = 0;
            
            DECLARE @DbScore INT = 0;
            DECLARE @Finding NVARCHAR(MAX) = ''No documentation metadata found'';
            
            IF @TotalObjects > 0
            BEGIN
                DECLARE @Pct FLOAT = CAST(@DocObjects AS FLOAT) / @TotalObjects * 100;
                IF @Pct >= 50 SET @DbScore = 2;
                ELSE IF @Pct > 0 SET @DbScore = 1;
                SET @Finding = CAST(@DocObjects AS NVARCHAR) + '' of '' + CAST(@TotalObjects AS NVARCHAR) + '' objects have extended properties ('' + CAST(@Pct AS NVARCHAR(5)) + ''%)'';
            END
            
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@p_DbName, @DbScore, @Finding);
            ';
            EXEC sp_executesql @Sql, N'@p_DbName NVARCHAR(128)', @p_DbName = @DbName;
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

SET @Finding = ISNULL(
    (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;