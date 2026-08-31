/* =============================================================================
   Checklist Item : 3.2.6
   Description    : Temp tables vs table variables chosen appropriately for
                    cardinality
   Scope          : DATABASE (every accessible user database)
   Read-only      : Yes - reads catalog metadata only (sys.sql_modules,
                    sys.objects, sys.schemas, sys.databases). No user data is
                    read, nothing is created, altered or dropped outside tempdb.
   Output         : Result, Score, DatabaseQueried, Finding
   ============================================================================= */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF OBJECT_ID('tempdb..#ScannedDbs') IS NOT NULL DROP TABLE #ScannedDbs;
IF OBJECT_ID('tempdb..#Defs')       IS NOT NULL DROP TABLE #Defs;
IF OBJECT_ID('tempdb..#Analysis')   IS NOT NULL DROP TABLE #Analysis;

CREATE TABLE #ScannedDbs
(
    DatabaseName SYSNAME NOT NULL
);

CREATE TABLE #Defs
(
    DatabaseName   SYSNAME       NOT NULL,
    ObjectFullName NVARCHAR(600) NOT NULL,
    Definition     NVARCHAR(MAX) NULL
);

/* Collector template. {DB} is replaced with a QUOTENAME-escaped database name on
   the non-Azure path, and removed entirely on Azure SQL Database, which supports
   only the current database context. */
DECLARE @Template NVARCHAR(MAX) = N'
INSERT INTO #Defs (DatabaseName, ObjectFullName, Definition)
SELECT @p_db, s.name + N''.'' + o.name, m.definition
FROM {DB}sys.sql_modules AS m
INNER JOIN {DB}sys.objects AS o ON o.object_id = m.object_id
INNER JOIN {DB}sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN (N''P'', N''FN'', N''TF'', N''TR'')
  AND m.definition IS NOT NULL
  AND (m.definition LIKE N''%#%'' OR m.definition LIKE N''%TABLE%'');';

DECLARE @db         SYSNAME,
        @sql        NVARCHAR(MAX),
        @FailedDbs  INT = 0;

IF @EngineEdition = 5   /* Azure SQL Database: current database only */
BEGIN
    SET @db = DB_NAME();
    SET @sql = REPLACE(@Template, N'{DB}', N'');

    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@p_db SYSNAME', @p_db = @db;
        INSERT INTO #ScannedDbs (DatabaseName) VALUES (@db);
    END TRY
    BEGIN CATCH
        SET @FailedDbs = @FailedDbs + 1;
    END CATCH
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4            /* skip master, tempdb, model, msdb */
          AND d.state = 0                  /* ONLINE only */
          AND d.source_database_id IS NULL /* skip snapshots */
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = REPLACE(@Template, N'{DB}', QUOTENAME(@db) + N'.');

        BEGIN TRY
            EXEC sys.sp_executesql @sql, N'@p_db SYSNAME', @p_db = @db;
            INSERT INTO #ScannedDbs (DatabaseName) VALUES (@db);
        END TRY
        BEGIN CATCH
            SET @FailedDbs = @FailedDbs + 1;
        END CATCH

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

/* Static pattern analysis. Line breaks and tabs are folded to spaces and runs of
   spaces collapsed so that formatting variations do not defeat the LIKE tests. */
SELECT
    d.DatabaseName,
    d.ObjectFullName,
    CAST(CASE WHEN n.Norm LIKE N'%DECLARE @% TABLE (%'
               OR n.Norm LIKE N'%DECLARE @% TABLE(%'
              THEN 1 ELSE 0 END AS BIT) AS UsesTableVariable,
    CAST(CASE WHEN n.Norm LIKE N'%CREATE TABLE #%'
               OR n.Norm LIKE N'% INTO #%'
              THEN 1 ELSE 0 END AS BIT) AS UsesTempTable,
    CAST(CASE WHEN n.Norm LIKE N'%INSERT INTO @% SELECT %FROM %'
               OR n.Norm LIKE N'%INSERT @% SELECT %FROM %'
              THEN 1 ELSE 0 END AS BIT) AS TableVarBulkPopulated,
    CAST(CASE WHEN n.Norm LIKE N'%OPTION (RECOMPILE)%'
               OR n.Norm LIKE N'%OPTION(RECOMPILE)%'
              THEN 1 ELSE 0 END AS BIT) AS HasRecompileHint
INTO #Analysis
FROM #Defs AS d
CROSS APPLY (SELECT UPPER(REPLACE(REPLACE(REPLACE(d.Definition, CHAR(13), N' '),
                                          CHAR(10), N' '), CHAR(9), N' ')) AS D1) AS a1
CROSS APPLY (SELECT REPLACE(REPLACE(REPLACE(a1.D1, N'  ', N' '),
                                    N'  ', N' '), N'  ', N' ') AS Norm) AS n;

DECLARE @DbCount        INT,
        @DbQueried      NVARCHAR(MAX),
        @TotalModules   INT = 0,
        @TableVarMods   INT = 0,
        @TempTableMods  INT = 0,
        @RiskyModules   INT = 0,
        @RiskyPct       DECIMAL(9,2) = 0,
        @Examples       NVARCHAR(1000),
        @Result         NVARCHAR(10),
        @Score          INT,
        @Finding        NVARCHAR(4000);

SELECT @DbCount = COUNT(*) FROM #ScannedDbs;

SELECT @DbQueried = STUFF((SELECT N', ' + sd.DatabaseName
                           FROM #ScannedDbs AS sd
                           ORDER BY sd.DatabaseName
                           FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

IF @DbQueried IS NULL SET @DbQueried = N'None';

SELECT @TotalModules  = COUNT(*),
       @TableVarMods  = SUM(CASE WHEN a.UsesTableVariable = 1 THEN 1 ELSE 0 END),
       @TempTableMods = SUM(CASE WHEN a.UsesTempTable = 1 THEN 1 ELSE 0 END),
       @RiskyModules  = SUM(CASE WHEN a.UsesTableVariable = 1
                                  AND a.TableVarBulkPopulated = 1
                                  AND a.HasRecompileHint = 0
                                 THEN 1 ELSE 0 END)
FROM #Analysis AS a
WHERE a.UsesTableVariable = 1 OR a.UsesTempTable = 1;

SET @TotalModules  = ISNULL(@TotalModules, 0);
SET @TableVarMods  = ISNULL(@TableVarMods, 0);
SET @TempTableMods = ISNULL(@TempTableMods, 0);
SET @RiskyModules  = ISNULL(@RiskyModules, 0);

IF @TableVarMods > 0
    SET @RiskyPct = CAST(@RiskyModules * 100.0 / @TableVarMods AS DECIMAL(9,2));

SELECT @Examples = STUFF((SELECT TOP (5) N', ' + a.DatabaseName + N'.' + a.ObjectFullName
                          FROM #Analysis AS a
                          WHERE a.UsesTableVariable = 1
                            AND a.TableVarBulkPopulated = 1
                            AND a.HasRecompileHint = 0
                          ORDER BY a.DatabaseName, a.ObjectFullName
                          FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N'');

IF @DbCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No user database could be read, so temp table versus table variable usage could not be assessed. Databases skipped or inaccessible: '
                   + CAST(@FailedDbs AS NVARCHAR(10))
                   + N'. Verify the audit login has CONNECT and VIEW DEFINITION on the target databases.';
END
ELSE IF @TotalModules = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Scanned ' + CAST(@DbCount AS NVARCHAR(10))
                   + N' user database(s); no user procedure, function or trigger uses a temp table or a table variable, so there is no inappropriate cardinality choice to report.';
END
ELSE IF @RiskyModules = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Scanned ' + CAST(@DbCount AS NVARCHAR(10)) + N' user database(s) and '
                   + CAST(@TotalModules AS NVARCHAR(10)) + N' module(s) using temporary structures ('
                   + CAST(@TempTableMods AS NVARCHAR(10)) + N' use temp tables, '
                   + CAST(@TableVarMods AS NVARCHAR(10)) + N' use table variables). No module bulk-populates a table variable from a base-table SELECT without OPTION (RECOMPILE), so the construct choice matches the expected cardinality in every module examined.';
END
ELSE IF @RiskyPct <= 10.00
BEGIN
    SET @Score = 2;
    SET @Finding = N'Scanned ' + CAST(@DbCount AS NVARCHAR(10))
                   + N' user database(s); construct choice is broadly correct but not consistent. '
                   + CAST(@RiskyModules AS NVARCHAR(10)) + N' of '
                   + CAST(@TableVarMods AS NVARCHAR(10)) + N' table-variable module(s) ('
                   + CAST(@RiskyPct AS NVARCHAR(10))
                   + N'%) bulk-populate a table variable with INSERT ... SELECT ... FROM and carry no OPTION (RECOMPILE), so the optimizer will estimate one row regardless of actual cardinality. Examples: '
                   + ISNULL(@Examples, N'n/a') + N'.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'Scanned ' + CAST(@DbCount AS NVARCHAR(10)) + N' user database(s). '
                   + CAST(@RiskyModules AS NVARCHAR(10)) + N' of '
                   + CAST(@TableVarMods AS NVARCHAR(10)) + N' table-variable module(s) ('
                   + CAST(@RiskyPct AS NVARCHAR(10))
                   + N'%) bulk-populate a table variable with INSERT ... SELECT ... FROM and carry no OPTION (RECOMPILE); table variables are being used as a default rather than chosen for low cardinality. Total modules using temporary structures: '
                   + CAST(@TotalModules AS NVARCHAR(10)) + N' ('
                   + CAST(@TempTableMods AS NVARCHAR(10)) + N' temp table, '
                   + CAST(@TableVarMods AS NVARCHAR(10)) + N' table variable). Examples: '
                   + ISNULL(@Examples, N'n/a') + N'.';
END

IF @DbCount > 0 AND @FailedDbs > 0
    SET @Finding = @Finding + N' Note: ' + CAST(@FailedDbs AS NVARCHAR(10))
                   + N' database(s) could not be read and were excluded.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result    AS Result,
    @Score     AS Score,
    @DbQueried AS DatabaseQueried,
    @Finding   AS Finding;

IF OBJECT_ID('tempdb..#Analysis')   IS NOT NULL DROP TABLE #Analysis;
IF OBJECT_ID('tempdb..#Defs')       IS NOT NULL DROP TABLE #Defs;
IF OBJECT_ID('tempdb..#ScannedDbs') IS NOT NULL DROP TABLE #ScannedDbs;