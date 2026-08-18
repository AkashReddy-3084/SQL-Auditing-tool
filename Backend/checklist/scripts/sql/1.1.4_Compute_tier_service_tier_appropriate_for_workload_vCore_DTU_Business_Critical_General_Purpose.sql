-- Checklist: Compute tier / service tier appropriate for workload (vCore/DTU, Business Critical/General Purpose)
-- Scope: DATABASE
-- Scoring: 3=Production tier (S1-S12, P1-P15, GP, BC, HS); 2=Valid tier/MI or indirect evidence; 1=Low-tier (Basic, S0); 0=Not Azure/Unknown/Unable to determine

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
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
        SET @Sql = N'DECLARE @SvcObj NVARCHAR(128);
        SELECT @SvcObj = current_service_objective FROM sys.database_service_objectives;
        DECLARE @TierScore INT;
        DECLARE @TierFinding NVARCHAR(MAX);
        IF @SvcObj IS NULL
        BEGIN
            SET @TierScore = 0;
            SET @TierFinding = ''Service tier information unavailable'';
        END
        ELSE
        BEGIN
            SET @TierFinding = ''Current tier: '' + @SvcObj;
            IF @SvcObj IN (''Basic'', ''S0'')
                SET @TierScore = 1;
            ELSE IF @SvcObj LIKE ''S%'' OR @SvcObj LIKE ''P%'' OR @SvcObj LIKE ''GP%'' OR @SvcObj LIKE ''BC%'' OR @SvcObj LIKE ''HS%''
                SET @TierScore = 3;
            ELSE
                SET @TierScore = 2;
        END
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@pDbName, @TierScore, @TierFinding);';
        EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed');
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
            DECLARE @SvcObj NVARCHAR(128);
            IF OBJECT_ID(''sys.database_service_objectives'') IS NOT NULL
            BEGIN
                SELECT @SvcObj = current_service_objective FROM sys.database_service_objectives;
            END
            DECLARE @TierScore INT;
            DECLARE @TierFinding NVARCHAR(MAX);
            IF @SvcObj IS NULL
            BEGIN
                SET @TierScore = 0;
                SET @TierFinding = ''Service tier information unavailable (non-Azure platform)'';
            END
            ELSE
            BEGIN
                SET @TierFinding = ''Current tier: '' + @SvcObj;
                IF @SvcObj IN (''Basic'', ''S0'')
                    SET @TierScore = 1;
                ELSE IF @SvcObj LIKE ''S%'' OR @SvcObj LIKE ''P%'' OR @SvcObj LIKE ''GP%'' OR @SvcObj LIKE ''BC%'' OR @SvcObj LIKE ''HS%''
                    SET @TierScore = 3;
                ELSE
                    SET @TierScore = 2;
            END
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@pDbName, @TierScore, @TierFinding);';
            EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed');
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