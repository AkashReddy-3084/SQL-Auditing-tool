-- Checklist: Pre/post-deployment scripts managed and idempotent
-- Scope: DATABASE
-- Scoring: 0: No idempotent patterns or deployment tracking. 1: <20% idempotent DDL or no tracking. 2: >=20% idempotent DDL and/or basic tracking. 3: >=50% idempotent DDL and clear deployment tracking.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    DECLARE @TotalModules INT;
    DECLARE @IdempotentModules INT;
    DECLARE @TrackingProps INT;
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    SELECT @TotalModules = COUNT(*) FROM sys.sql_modules;
    SELECT @IdempotentModules = COUNT(*) FROM sys.sql_modules
    WHERE definition LIKE ''%IF NOT EXISTS%''
       OR definition LIKE ''%CREATE OR ALTER%''
       OR definition LIKE ''%MERGE%''
       OR definition LIKE ''%ALTER%'';
    SELECT @TrackingProps = COUNT(*) FROM sys.extended_properties
    WHERE name LIKE ''%Deploy%'' OR name LIKE ''%Version%'' OR name LIKE ''%CI%'' OR name LIKE ''%CD%'';

    IF @TotalModules = 0 BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''No modules found'';
    END ELSE BEGIN
        DECLARE @Pct FLOAT = CAST(@IdempotentModules AS FLOAT) / @TotalModules * 100;
        IF @Pct >= 50 AND @TrackingProps > 0 SET @DbScore = 3;
        ELSE IF @Pct >= 20 OR @TrackingProps > 0 SET @DbScore = 2;
        ELSE IF @Pct > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        SET @DbFinding = CAST(@IdempotentModules AS NVARCHAR) + ''/'' + CAST(@TotalModules AS NVARCHAR) + '' modules idempotent ('' + CAST(@Pct AS NVARCHAR) + ''%), '' + CAST(@TrackingProps AS NVARCHAR) + '' deployment tracking properties'';
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
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
            DECLARE @TotalModules INT;
            DECLARE @IdempotentModules INT;
            DECLARE @TrackingProps INT;
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            SELECT @TotalModules = COUNT(*) FROM sys.sql_modules;
            SELECT @IdempotentModules = COUNT(*) FROM sys.sql_modules
            WHERE definition LIKE ''%IF NOT EXISTS%''
               OR definition LIKE ''%CREATE OR ALTER%''
               OR definition LIKE ''%MERGE%''
               OR definition LIKE ''%ALTER%'';
            SELECT @TrackingProps = COUNT(*) FROM sys.extended_properties
            WHERE name LIKE ''%Deploy%'' OR name LIKE ''%Version%'' OR name LIKE ''%CI%'' OR name LIKE ''%CD%'';

            IF @TotalModules = 0 BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''No modules found'';
            END ELSE BEGIN
                DECLARE @Pct FLOAT = CAST(@IdempotentModules AS FLOAT) / @TotalModules * 100;
                IF @Pct >= 50 AND @TrackingProps > 0 SET @DbScore = 3;
                ELSE IF @Pct >= 20 OR @TrackingProps > 0 SET @DbScore = 2;
                ELSE IF @Pct > 0 SET @DbScore = 1;
                ELSE SET @DbScore = 0;

                SET @DbFinding = CAST(@IdempotentModules AS NVARCHAR) + ''/'' + CAST(@TotalModules AS NVARCHAR) + '' modules idempotent ('' + CAST(@Pct AS NVARCHAR) + ''%), '' + CAST(@TrackingProps AS NVARCHAR) + '' deployment tracking properties'';
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore, @DbFinding);
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