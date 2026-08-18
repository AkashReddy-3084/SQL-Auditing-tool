-- Checklist: Business glossary / terminology maintained
-- Scope: DATABASE
-- Scoring: 0=No evidence; 1=<20% coverage; 2=20-79% coverage; 3=>=80% coverage or dedicated glossary table exists
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
    SET @Sql = N'
    DECLARE @TotalTables INT;
    DECLARE @CoveredTables INT;
    DECLARE @GlossaryTableExists BIT = 0;
    DECLARE @CoveragePct DECIMAL(5,2);
    DECLARE @SampleTables NVARCHAR(MAX);

    SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
    
    SELECT @CoveredTables = COUNT(DISTINCT t.object_id)
    FROM sys.tables t
    WHERE t.type = ''U''
      AND EXISTS (
          SELECT 1 FROM sys.extended_properties ep
          WHERE ep.major_id = t.object_id AND ep.minor_id = 0
            AND (ep.name = ''MS_Description'' OR ep.name LIKE ''%glossary%'' OR ep.name LIKE ''%business%'' OR ep.name LIKE ''%term%'')
      );

    SELECT @GlossaryTableExists = 1
    FROM sys.tables t
    WHERE t.type = ''U''
      AND (t.name LIKE ''%Glossary%'' OR t.name LIKE ''%BusinessTerm%'' OR t.name LIKE ''%DataDictionary%'' OR t.name LIKE ''%Metadata%'');

    SET @CoveragePct = CASE WHEN @TotalTables > 0 THEN (@CoveredTables * 100.0) / @TotalTables ELSE 0 END;

    SELECT @SampleTables = STRING_AGG(t.name, '', '')
    FROM sys.tables t
    WHERE t.type = ''U''
      AND EXISTS (
          SELECT 1 FROM sys.extended_properties ep
          WHERE ep.major_id = t.object_id AND ep.minor_id = 0
            AND (ep.name = ''MS_Description'' OR ep.name LIKE ''%glossary%'' OR ep.name LIKE ''%business%'' OR ep.name LIKE ''%term%'')
      );

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        @pDbName,
        CASE 
            WHEN @GlossaryTableExists = 1 THEN 3
            WHEN @CoveragePct >= 80 THEN 3
            WHEN @CoveragePct >= 20 THEN 2
            WHEN @CoveragePct > 0 THEN 1
            ELSE 0
        END,
        ''Coverage: '' + CAST(@CoveragePct AS NVARCHAR(10)) + ''% ('' + CAST(@CoveredTables AS NVARCHAR(10)) + ''/' + CAST(@TotalTables AS NVARCHAR(10)) + ''). '' +
        CASE WHEN @GlossaryTableExists = 1 THEN ''Dedicated glossary table found. '' ELSE '''' END +
        CASE WHEN @SampleTables IS NOT NULL THEN ''Sample covered: '' + @SampleTables ELSE ''No covered tables found.'' END
    );
    ';
    EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT