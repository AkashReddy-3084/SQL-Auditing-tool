-- Checklist: Data quality framework formally defined with rules, ownership, and scoring
-- Scope: DATABASE
-- Scoring: 0: No DQ-related metadata or objects found. 1: Limited DQ references found. 2: Multiple DQ-related extended properties or dedicated DQ metadata tables found, but framework completeness requires human review. 3: Not applicable for automated evaluation; capped at 2 due to governance/documentation nature.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    BEGIN TRY
        SET @Sql = N'
        DECLARE @DQProps INT = 0;
        DECLARE @DQTables INT = 0;
        DECLARE @DbScore INT = 0;
        DECLARE @DbFinding NVARCHAR(MAX) = ''No DQ-related metadata or objects found.'';

        SELECT @DQProps = COUNT(*)
        FROM sys.extended_properties ep
        JOIN sys.objects o ON ep.major_id = o.object_id
        WHERE ep.name LIKE ''%DQ%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%data quality%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%ownership%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%scoring%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%rule%'';

        SELECT @DQTables = COUNT(*)
        FROM sys.tables t
        WHERE t.name LIKE ''DQ_%'' OR t.name LIKE ''DataQuality_%'' OR t.name LIKE ''%Quality%'';

        IF @DQProps > 0 OR @DQTables > 0
        BEGIN
            SET @DbFinding = ''Found '' + CAST(@DQProps AS NVARCHAR) + '' DQ-related extended properties and '' + CAST(@DQTables AS NVARCHAR) + '' DQ-related tables.'';
            IF @DQProps + @DQTables >= 3 SET @DbScore = 2;
            ELSE SET @DbScore = 1;
        END
        ELSE
        BEGIN
            SET @DbScore = 0;
        END

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
            DECLARE @DQProps INT = 0;
            DECLARE @DQTables INT = 0;
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = ''No DQ-related metadata or objects found.'';

            SELECT @DQProps = COUNT(*)
            FROM sys.extended_properties ep
            JOIN sys.objects o ON ep.major_id = o.object_id
            WHERE ep.name LIKE ''%DQ%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%data quality%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%ownership%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%scoring%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%rule%'';

            SELECT @DQTables = COUNT(*)
            FROM sys.tables t
            WHERE t.name LIKE ''DQ_%'' OR t.name LIKE ''DataQuality_%'' OR t.name LIKE ''%Quality%'';

            IF @DQProps > 0 OR @DQTables > 0
            BEGIN
                SET @DbFinding = ''Found '' + CAST(@DQProps AS NVARCHAR) + '' DQ-related extended properties and '' + CAST(@DQTables AS NVARCHAR) + '' DQ-related tables.'';
                IF @DQProps + @DQTables >= 3 SET @DbScore = 2;
                ELSE SET @DbScore = 1;
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
            END

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