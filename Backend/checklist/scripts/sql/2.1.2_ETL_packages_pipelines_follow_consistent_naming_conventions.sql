-- Checklist: ETL packages/pipelines follow consistent naming conventions
-- Scope: DATABASE
-- Scoring: 3: No ETL objects found or 100% consistent. 2: >=70% consistency detected (capped at 2 per guidelines for naming conventions requiring human validation). 1: 40-69% consistency with significant deviations. 0: <40% consistency or completely random naming.

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
    DECLARE @Total INT;
    DECLARE @DominantPrefix NVARCHAR(128);
    DECLARE @MatchCount INT;
    DECLARE @Pct FLOAT;
    DECLARE @NonCompliant NVARCHAR(MAX);
    DECLARE @AllObjects NVARCHAR(MAX);
    DECLARE @DbScore INT = 0;
    DECLARE @Finding NVARCHAR(MAX) = '';

    SELECT @Total = COUNT(*)
    FROM sys.objects
    WHERE type IN (''P'',''U'',''V'',''FN'',''IF'',''TF'')
      AND is_ms_shipped = 0
      AND (name LIKE ''%ETL%'' OR name LIKE ''%Load%'' OR name LIKE ''%Staging%'' OR name LIKE ''%Extract%'' OR name LIKE ''%Transform%'' OR name LIKE ''%Ingest%'' OR name LIKE ''%Sync%'' OR name LIKE ''%Pipeline%'');

    IF @Total = 0
    BEGIN
        SET @DbScore = 3;
        SET @Finding = ''No ETL objects found.'';
    END
    ELSE
    BEGIN
        SELECT TOP 1 @DominantPrefix = LEFT(name, CHARINDEX(''_ '', name + ''_'') - 1)
        FROM sys.objects
        WHERE type IN (''P'',''U'',''V'',''FN'',''IF'',''TF'')
          AND is_ms_shipped = 0
          AND (name LIKE ''%ETL%'' OR name LIKE ''%Load%'' OR name LIKE ''%Staging%'' OR name LIKE ''%Extract%'' OR name LIKE ''%Transform%'' OR name LIKE ''%Ingest%'' OR name LIKE ''%Sync%'' OR name LIKE ''%Pipeline%'')
        GROUP BY LEFT(name, CHARINDEX(''_ '', name + ''_'') - 1)
        ORDER BY COUNT(*) DESC;

        SELECT @MatchCount = COUNT(*)
        FROM sys.objects
        WHERE type IN (''P'',''U'',''V'',''FN'',''IF'',''TF'')
          AND is_ms_shipped = 0
          AND (name LIKE ''%ETL%'' OR name LIKE ''%Load%'' OR name LIKE ''%Staging%'' OR name LIKE ''%Extract%'' OR name LIKE ''%Transform%'' OR name LIKE ''%Ingest%'' OR name LIKE ''%Sync%'' OR name LIKE ''%Pipeline%'')
          AND LEFT(name, CHARINDEX(''_ '', name + ''_'') - 1) = @DominantPrefix;

        SET @Pct = CAST(@MatchCount AS FLOAT) / @Total * 100;

        SELECT @NonCompliant = STRING_AGG(name, '', '')
        FROM sys.objects
        WHERE type IN (''P'',''U'',''V'',''FN'',''IF'',''TF'')
          AND is_ms_shipped = 0
          AND (name LIKE ''%ETL%'' OR name LIKE ''%Load%'' OR name LIKE ''%Staging%'' OR name LIKE ''%Extract%'' OR name LIKE ''%Transform%'' OR name LIKE ''%Ingest%'' OR name LIKE ''%Sync%'' OR name LIKE ''%Pipeline%'')
          AND LEFT(name, CHARINDEX(''_ '', name + ''_'') - 1) <> @DominantPrefix;

        SELECT @AllObjects = STRING_AGG(name, '', '')
        FROM sys.objects
        WHERE type IN (''P'',''U'',''V'',''FN'',''IF'',''TF'')
          AND is_ms_shipped = 0
          AND (name LIKE ''%ETL%'' OR name LIKE ''%Load%'' OR name LIKE ''%Staging%'' OR name LIKE ''%Extract%'' OR name LIKE ''%Transform%'' OR name LIKE ''%Ingest%'' OR name LIKE ''%Sync%'' OR name LIKE ''%Pipeline%'');

        IF @Pct >= 100
        BEGIN
            SET @DbScore = 3;
            SET @Finding = ''100% consistent prefix ['' + @DominantPrefix + '']. -- NOTE: This script provides automated evidence. Full compliance requires human review.'';
        END
        ELSE IF @Pct >= 70
        BEGIN
            SET @DbScore = 2;
            SET @Finding = ''Consistency: '' + CAST(@Pct AS VARCHAR(10)) + ''% follow prefix ['' + @DominantPrefix + '']. '' + ISNULL(@NonCompliant, ''No deviations.'') + '' -- NOTE: This script provides automated evidence. Full compliance requires human review.'';
        END
        ELSE IF @Pct >= 40
        BEGIN
            SET @DbScore = 1;
            SET @Finding = ''Consistency: '' + CAST(@Pct AS VARCHAR(10)) + ''% follow prefix ['' + @DominantPrefix + '']. Significant deviations: '' + ISNULL(@NonCompliant, ''None'');
        END
        ELSE
        BEGIN
            SET @DbScore = 0;
            SET @Finding = ''No consistent pattern. Objects: '' + @AllObjects;
        END
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @Finding);
    ';
    EXEC sp_executesql @Sql;
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
            DECLARE @Total INT;
            DECLARE @DominantPrefix NVARCHAR(128);
            DECLARE @MatchCount INT;
            DECLARE @Pct FLOAT;
            DECLARE @NonCompliant NVARCHAR(MAX);
            DECLARE @AllObjects NVARCHAR(MAX);
            DECLARE @DbScore INT = 0;
            DECLARE @Finding NVARCHAR(MAX) = '';

            SELECT @Total = COUNT(*)
            FROM sys.objects
            WHERE type IN (''P'',''U'',''V'',''FN'',''IF'',''TF'')
              AND is_ms_shipped = 0
              AND (name LIKE ''%ETL%'' OR name LIKE ''%Load%'' OR name LIKE ''%Staging%'' OR name LIKE ''%Extract%'' OR