SET NOCOUNT ON;

DECLARE @Result NVARCHAR(50);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @IsAzureDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @HasClassificationView BIT = CASE WHEN TRY_CONVERT(INT, SERVERPROPERTY('ProductMajorVersion')) >= 15 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (DbName SYSNAME, ClassifiedCols INT, LabelledCols INT);

IF @IsAzureDb = 1
BEGIN
    DECLARE @AzClassified INT = 0;
    DECLARE @AzLabelled INT = 0;

    IF OBJECT_ID('sys.sensitivity_classifications') IS NOT NULL
        EXEC sp_executesql N'SELECT @scOut = COUNT(*) FROM sys.sensitivity_classifications;', N'@scOut INT OUTPUT', @scOut = @AzClassified OUTPUT;

    SELECT @AzLabelled = COUNT(*)
    FROM sys.extended_properties
    WHERE class = 1
      AND name IN ('sys_information_type_name', 'sys_sensitivity_label_name');

    INSERT INTO #DbResults (DbName, ClassifiedCols, LabelledCols)
    VALUES (DB_NAME(), ISNULL(@AzClassified, 0), ISNULL(@AzLabelled, 0));
END
ELSE
BEGIN
    DECLARE @Db SYSNAME;
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE @Classified INT;
    DECLARE @Labelled INT;

    DECLARE DbCur CURSOR LOCAL FAST_FORWARD FOR
        SELECT name
        FROM sys.databases
        WHERE database_id > 4
          AND state_desc = 'ONLINE'
          AND HAS_DBACCESS(name) = 1;

    OPEN DbCur;
    FETCH NEXT FROM DbCur INTO @Db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Classified = 0;
        SET @Labelled = 0;

        SET @Sql = N'SELECT @epOut = COUNT(*) FROM ' + QUOTENAME(@Db) + N'.sys.extended_properties WHERE class = 1 AND name IN (''sys_information_type_name'', ''sys_sensitivity_label_name'');';
        EXEC sp_executesql @Sql, N'@epOut INT OUTPUT', @epOut = @Labelled OUTPUT;

        IF @HasClassificationView = 1
        BEGIN
            SET @Sql = N'SELECT @scOut = COUNT(*) FROM ' + QUOTENAME(@Db) + N'.sys.sensitivity_classifications;';
            EXEC sp_executesql @Sql, N'@scOut INT OUTPUT', @scOut = @Classified OUTPUT;
        END

        INSERT INTO #DbResults (DbName, ClassifiedCols, LabelledCols)
        VALUES (@Db, ISNULL(@Classified, 0), ISNULL(@Labelled, 0));

        FETCH NEXT FROM DbCur INTO @Db;
    END

    CLOSE DbCur;
    DEALLOCATE DbCur;
END

DECLARE @TotalDbs INT = (SELECT COUNT(*) FROM #DbResults);
DECLARE @ClassifiedDbs INT = (SELECT COUNT(*) FROM #DbResults WHERE ClassifiedCols > 0 OR LabelledCols > 0);
DECLARE @Pct DECIMAL(5, 2) = CASE WHEN @TotalDbs = 0 THEN 0 ELSE (@ClassifiedDbs * 100.0) / @TotalDbs END;

IF @TotalDbs = 0
BEGIN
    SET @Result = 'Fail';
    SET @Score = 0;
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Pct >= 90 THEN 3 WHEN @Pct >= 70 THEN 2 WHEN @Pct >= 40 THEN 1 ELSE 0 END;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    SET @DatabaseQueried = ISNULL(STUFF((SELECT ', ' + DbName FROM #DbResults ORDER BY DbName FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), 'None');

    SET @Finding = ISNULL(
        CONVERT(NVARCHAR(20), @ClassifiedDbs) + ' of ' + CONVERT(NVARCHAR(20), @TotalDbs)
        + ' user database(s) (' + CONVERT(NVARCHAR(20), @Pct) + '%) contain sensitive data classifications; unclassified: '
        + ISNULL(STUFF((SELECT ', ' + DbName FROM #DbResults WHERE ClassifiedCols = 0 AND LabelledCols = 0 ORDER BY DbName FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), 'none'),
        'No database found to be queried');
END

DROP TABLE #DbResults;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;