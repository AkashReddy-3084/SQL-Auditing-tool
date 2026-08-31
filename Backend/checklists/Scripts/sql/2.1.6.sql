/*
    Checklist item 2.1.6 - ETL is metadata-driven or well-modularized where appropriate
    Read-only proxy assessment based on SQL Server catalog views.
    Output: Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
IF OBJECT_ID('tempdb..#EtlFindings') IS NOT NULL DROP TABLE #EtlFindings;

CREATE TABLE #Dbs
(
    DatabaseName sysname NOT NULL
);

CREATE TABLE #EtlFindings
(
    DatabaseName        sysname NOT NULL,
    MetadataTableCount  int     NOT NULL,
    EtlProcedureCount   int     NOT NULL,
    ModularProcCount    int     NOT NULL,
    MonolithicProcCount int     NOT NULL
);

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: cross-database enumeration is not available */
    INSERT INTO #Dbs (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @MetaFilter nvarchar(max) =
    N'(LOWER(t.name) LIKE ''%etl%config%'' OR LOWER(t.name) LIKE ''%etl%control%'' OR LOWER(t.name) LIKE ''%etl%metadata%''' +
    N' OR LOWER(t.name) LIKE ''%load%control%'' OR LOWER(t.name) LIKE ''%load%config%'' OR LOWER(t.name) LIKE ''%batch%control%''' +
    N' OR LOWER(t.name) LIKE ''%pipeline%config%'' OR LOWER(t.name) LIKE ''%ingest%config%'' OR LOWER(t.name) LIKE ''%source%target%''' +
    N' OR LOWER(t.name) LIKE ''%column%map%'' OR LOWER(t.name) LIKE ''%process%metadata%'' OR LOWER(t.name) LIKE ''%job%config%''' +
    N' OR LOWER(t.name) LIKE ''%control%table%'' OR LOWER(t.name) LIKE ''%mapping%'')';

DECLARE @ProcFilter nvarchar(max) =
    N'(LOWER(p.name) LIKE ''%etl%'' OR LOWER(p.name) LIKE ''%load%'' OR LOWER(p.name) LIKE ''%stag%''' +
    N' OR LOWER(p.name) LIKE ''%transform%'' OR LOWER(p.name) LIKE ''%import%'' OR LOWER(p.name) LIKE ''%extract%''' +
    N' OR LOWER(p.name) LIKE ''%ingest%'' OR LOWER(p.name) LIKE ''%merge%'' OR LOWER(p.name) LIKE ''%populate%''' +
    N' OR LOWER(p.name) LIKE ''%refresh%'')';

DECLARE @DbName    sysname;
DECLARE @UsePrefix nvarchar(300);
DECLARE @Sql       nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Dbs ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @UsePrefix = CASE WHEN @EngineEdition = 5 THEN N'' ELSE N'USE ' + QUOTENAME(@DbName) + N'; ' END;

        SET @Sql = @UsePrefix + N'
        SELECT
            @p_Db AS DatabaseName,
            (SELECT COUNT(*)
               FROM sys.tables AS t
              WHERE t.is_ms_shipped = 0
                AND ' + @MetaFilter + N') AS MetadataTableCount,
            (SELECT COUNT(*)
               FROM sys.procedures AS p
              WHERE p.is_ms_shipped = 0
                AND ' + @ProcFilter + N') AS EtlProcedureCount,
            (SELECT COUNT(*)
               FROM sys.procedures AS p
               INNER JOIN sys.sql_modules AS m ON m.object_id = p.object_id
              WHERE p.is_ms_shipped = 0
                AND ' + @ProcFilter + N'
                AND (m.definition LIKE ''%EXEC %'' OR m.definition LIKE ''%EXECUTE %'')) AS ModularProcCount,
            (SELECT COUNT(*)
               FROM sys.procedures AS p
               INNER JOIN sys.sql_modules AS m ON m.object_id = p.object_id
              WHERE p.is_ms_shipped = 0
                AND ' + @ProcFilter + N'
                AND LEN(m.definition) > 10000
                AND m.definition NOT LIKE ''%EXEC %''
                AND m.definition NOT LIKE ''%EXECUTE %'') AS MonolithicProcCount;';

        INSERT INTO #EtlFindings (DatabaseName, MetadataTableCount, EtlProcedureCount, ModularProcCount, MonolithicProcCount)
        EXEC sp_executesql @Sql, N'@p_Db sysname', @p_Db = @DbName;
    END TRY
    BEGIN CATCH
        /* Database not accessible or definitions not visible - skip it */
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @DbsScanned     int = (SELECT COUNT(*) FROM #EtlFindings);
DECLARE @TotalMeta      int = ISNULL((SELECT SUM(MetadataTableCount)  FROM #EtlFindings), 0);
DECLARE @TotalEtlProcs  int = ISNULL((SELECT SUM(EtlProcedureCount)   FROM #EtlFindings), 0);
DECLARE @TotalModular   int = ISNULL((SELECT SUM(ModularProcCount)    FROM #EtlFindings), 0);
DECLARE @TotalMono      int = ISNULL((SELECT SUM(MonolithicProcCount) FROM #EtlFindings), 0);
DECLARE @DbsBothSignals int = (SELECT COUNT(*) FROM #EtlFindings WHERE MetadataTableCount >= 1 AND ModularProcCount >= 1);

DECLARE @ModularPct decimal(5,1) =
    CASE WHEN @TotalEtlProcs = 0 THEN CAST(0 AS decimal(5,1))
         ELSE CAST(@TotalModular * 100.0 / @TotalEtlProcs AS decimal(5,1)) END;

DECLARE @DbList nvarchar(max) =
    STUFF((SELECT N', ' + f.DatabaseName
             FROM #EtlFindings AS f
            ORDER BY f.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @Score   int;
DECLARE @Result  nvarchar(20);
DECLARE @Finding nvarchar(max);

DECLARE @Stats nvarchar(max) =
    N'Databases inspected: ' + CAST(@DbsScanned AS nvarchar(20)) +
    N'; ETL metadata/control/mapping tables: ' + CAST(@TotalMeta AS nvarchar(20)) +
    N'; ETL-named stored procedures: ' + CAST(@TotalEtlProcs AS nvarchar(20)) +
    N'; procedures delegating to other modules: ' + CAST(@TotalModular AS nvarchar(20)) +
    N' (' + CAST(@ModularPct AS nvarchar(20)) + N'%)' +
    N'; large self-contained (monolithic) ETL procedures: ' + CAST(@TotalMono AS nvarchar(20)) + N'.';

IF @DbsScanned = 0
BEGIN
    SET @Score   = 0;
    SET @Finding = N'No user database could be inspected (no accessible user databases, or catalog metadata is not visible to the audit login). ETL modularity could not be assessed.';
END
ELSE IF @DbsBothSignals > 0 AND @ModularPct >= 50
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Metadata-driven and modular ETL indicators found: ' + CAST(@DbsBothSignals AS nvarchar(20)) +
                   N' database(s) contain both ETL metadata/control tables and ETL procedures that delegate to other modules. ' + @Stats;
END
ELSE IF @TotalMeta > 0 OR @ModularPct >= 50
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Only one of the two indicators is present - either ETL configuration/control tables exist without modular procedures, or procedures are modular without a metadata layer. ' + @Stats;
END
ELSE IF @TotalEtlProcs > 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'ETL logic appears hard-coded: ETL-named stored procedures exist but no ETL metadata/control/mapping tables were found and fewer than 50% of the procedures delegate to other modules. ' + @Stats;
END
ELSE
BEGIN
    SET @Score   = 1;
    SET @Finding = N'No ETL artifacts were detected inside SQL Server (no ETL-named procedures and no metadata/control tables). ETL is most likely implemented outside the database (e.g. Azure Data Factory, SSIS, Fabric pipelines); assess metadata-driven design and modularity in that tool. ' + @Stats;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result                  AS Result,
    @Score                   AS Score,
    ISNULL(@DbList, N'None') AS DatabaseQueried,
    @Finding                 AS Finding;