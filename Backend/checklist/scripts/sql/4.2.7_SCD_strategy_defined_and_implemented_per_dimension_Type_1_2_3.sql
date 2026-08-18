-- Checklist: SCD strategy defined and implemented per dimension (Type 1/2/3)
-- Scope: DATABASE
-- Scoring: 0=No dimension tables or no SCD evidence; 1=Partial evidence (<50% compliant); 2=Majority compliant (>=50%); 3=All dimension tables have SCD evidence (columns or extended properties)

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
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
    DECLARE @DimTables TABLE (TableName NVARCHAR(128), HasSCDEvidence BIT);
    INSERT INTO @DimTables
    SELECT 
        QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name),
        CASE WHEN EXISTS (
            SELECT 1 FROM sys.extended_properties ep 
            WHERE ep.major_id = t.object_id AND ep.minor_id = 0 
            AND (ep.name LIKE ''%SCD%'' OR ep.value LIKE ''%Type [123]%'')
        ) OR EXISTS (
            SELECT 1 FROM sys.columns c 
            WHERE c.object_id = t.object_id 
            AND c.name IN (''StartDate'', ''EndDate'', ''CurrentFlag'', ''IsActive'', ''EffectiveDate'', ''ExpirationDate'', ''ValidFrom'', ''ValidTo'', ''IsCurrent'')
        ) THEN 1 ELSE 0 END
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name = ''Dim'' OR t.name LIKE ''Dim%'';

    DECLARE @Total INT = (SELECT COUNT(*) FROM @DimTables);
    DECLARE @Compliant INT = (SELECT COUNT(*) FROM @DimTables WHERE HasSCDEvidence = 1);
    DECLARE @NonCompliantList NVARCHAR(MAX) = (SELECT STRING_AGG(TableName, '', '') FROM @DimTables WHERE HasSCDEvidence = 0);
    DECLARE @DbScore INT = 0;
    DECLARE @Finding NVARCHAR(MAX) = '''';

    IF @Total = 0 
    BEGIN
        SET @DbScore = 0;
        SET @Finding = ''No dimension tables identified'';
    END
    ELSE IF @Compliant = @Total 
    BEGIN
        SET @DbScore = 3;
        SET @Finding = ''All '' + CAST(@Total AS NVARCHAR) + '' dimension tables have SCD evidence'';
    END
    ELSE IF @Compliant > (@Total * 0.5) 
    BEGIN
        SET @DbScore = 2;
        SET @Finding = ''SCD evidence missing in: '' + ISNULL(@NonCompliantList, ''None'');
    END
    ELSE 
    BEGIN
        SET @DbScore = 1;
        SET @Finding = ''SCD evidence missing in: '' + ISNULL(@NonCompliantList, ''None'');
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + QUOTENAME(@DbName, '''') + ''', @DbScore, @Finding);
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
            DECLARE @DimTables TABLE (TableName NVARCHAR(128), HasSCDEvidence BIT);
            INSERT INTO @DimTables
            SELECT 
                QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name),
                CASE WHEN EXISTS (
                    SELECT 1 FROM sys.extended_properties ep 
                    WHERE ep.major_id = t.object_id AND ep.minor_id = 0 
                    AND (ep.name LIKE ''%SCD%'' OR ep.value LIKE ''%Type [123]%'')
                ) OR EXISTS (
                    SELECT 1 FROM sys.columns c 
                    WHERE c.object_id = t.object_id 
                    AND c.name IN (''StartDate'', ''EndDate'', ''CurrentFlag'', ''IsActive'', ''EffectiveDate'', ''ExpirationDate'', ''ValidFrom'', ''ValidTo'', ''IsCurrent'')
                ) THEN 1 ELSE 0 END
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE s.name = ''Dim'' OR t.name LIKE ''Dim%'';

            DECLARE @Total INT = (SELECT COUNT(*) FROM @DimTables);
            DECLARE @Compliant INT = (SELECT COUNT(*) FROM @DimTables WHERE HasSCDEvidence = 1);
            DECLARE @NonCompliantList NVARCHAR(MAX) = (SELECT STRING_AGG(TableName, '', '') FROM @DimTables WHERE HasSCDEvidence = 0);
            DECLARE @DbScore INT = 0;
            DECLARE @Finding NVARCHAR(MAX) = '''';

            IF @Total = 0 
            BEGIN
                SET @DbScore = 0;
                SET @Finding = ''No dimension tables identified'';
            END
            ELSE IF @Compliant = @Total 
            BEGIN
                SET @DbScore = 3;
                SET @Finding = ''All '' + CAST(@Total AS NVARCHAR) + '' dimension tables have SCD evidence'';
            END
            ELSE IF @Compliant > (@Total * 0.5) 
            BEGIN
                SET @DbScore = 2;
                SET @Finding = ''SCD evidence missing in: '' + ISNULL(@NonCompliantList, ''None'');
            END
            ELSE 
            BEGIN
                SET @DbScore = 1;
                SET @Finding = ''SCD evidence missing in: '' + ISNULL(@NonCompliantList, ''None'');
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + QUOTENAME(@DbName, '''') + ''', @DbScore, @Finding);
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