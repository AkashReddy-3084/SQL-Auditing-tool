/* Checklist 2.3.3 - Bad/rejected rows routed to a quarantine/error table
   (not silently dropped or failing the batch).
   Read-only catalog scan. Proxy evidence: quarantine/reject/error landing tables,
   SSIS-style error-output columns, and modules that write to those tables. */
SET NOCOUNT ON;

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
CREATE TABLE #Dbs (DatabaseName sysname NOT NULL PRIMARY KEY);

IF OBJECT_ID('tempdb..#DbScan') IS NOT NULL DROP TABLE #DbScan;
CREATE TABLE #DbScan
(
    DatabaseName      sysname        NOT NULL,
    QuarantineTables  int            NULL,
    ErrorColumnTables int            NULL,
    ModuleReferences  int            NULL,
    SampleObjects     nvarchar(1000) NULL
);

IF @EngineEdition = 5   -- Azure SQL Database: cross-database queries are not possible
    INSERT INTO #Dbs (DatabaseName) VALUES (DB_NAME());
ELSE
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_in_standby = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @db sysname, @prefix nvarchar(300), @sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Dbs ORDER BY DatabaseName;
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @prefix = CASE WHEN @EngineEdition = 5 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

    SET @sql = N'
INSERT INTO #DbScan (DatabaseName, QuarantineTables, ErrorColumnTables, ModuleReferences, SampleObjects)
SELECT @dbn,
       (SELECT COUNT(*)
          FROM ' + @prefix + N'sys.tables AS t
         WHERE t.is_ms_shipped = 0
           AND (t.name LIKE ''%quarantine%''   OR t.name LIKE ''%reject%''
             OR t.name LIKE ''%error%''        OR t.name LIKE ''%exception%''
             OR t.name LIKE ''%err[_]%''       OR t.name LIKE ''%[_]err''
             OR t.name LIKE ''%badrow%''       OR t.name LIKE ''%bad[_]row%''
             OR t.name LIKE ''%deadletter%''   OR t.name LIKE ''%dead[_]letter%''
             OR t.name LIKE ''%invalidrow%''   OR t.name LIKE ''%failedrow%'')),
       (SELECT COUNT(*)
          FROM ' + @prefix + N'sys.tables AS t
         WHERE t.is_ms_shipped = 0
           AND EXISTS (SELECT 1
                         FROM ' + @prefix + N'sys.columns AS c
                        WHERE c.object_id = t.object_id
                          AND c.name IN (''ErrorCode'', ''ErrorColumn'', ''ErrorMessage'',
                                         ''ErrorDescription'', ''RejectReason'', ''RejectionReason''))),
       (SELECT COUNT(DISTINCT m.object_id)
          FROM ' + @prefix + N'sys.sql_modules AS m
         WHERE EXISTS (SELECT 1
                         FROM ' + @prefix + N'sys.tables AS t
                        WHERE t.is_ms_shipped = 0
                          AND (t.name LIKE ''%quarantine%'' OR t.name LIKE ''%reject%''
                            OR t.name LIKE ''%error%''      OR t.name LIKE ''%exception%''
                            OR t.name LIKE ''%badrow%'')
                          AND m.definition LIKE ''%'' + t.name + ''%'')),
       STUFF((SELECT TOP (5) '', '' + s.name + ''.'' + t.name
                FROM ' + @prefix + N'sys.tables AS t
                JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
               WHERE t.is_ms_shipped = 0
                 AND (t.name LIKE ''%quarantine%'' OR t.name LIKE ''%reject%''
                   OR t.name LIKE ''%error%''      OR t.name LIKE ''%exception%''
                   OR t.name LIKE ''%badrow%'')
               ORDER BY t.name
                 FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(1000)''), 1, 2, '''');';

    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@dbn sysname', @dbn = @db;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbScan (DatabaseName, QuarantineTables, ErrorColumnTables, ModuleReferences, SampleObjects)
        VALUES (@db, NULL, NULL, NULL, N'Not scanned: ' + LEFT(ERROR_MESSAGE(), 200));
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @TotalDbs        int,
        @ScannedDbs      int,
        @DbsWithTables   int,
        @DbsWithErrCols  int,
        @DbsWithRefs     int,
        @TableCount      int,
        @ModuleCount     int,
        @Samples         nvarchar(max),
        @DatabaseQueried nvarchar(max),
        @Finding         nvarchar(max),
        @Result          nvarchar(20),
        @Score           int;

SELECT @TotalDbs = COUNT(*) FROM #Dbs;

SELECT @ScannedDbs     = SUM(CASE WHEN QuarantineTables IS NOT NULL THEN 1 ELSE 0 END),
       @DbsWithTables  = SUM(CASE WHEN ISNULL(QuarantineTables, 0)  > 0 THEN 1 ELSE 0 END),
       @DbsWithErrCols = SUM(CASE WHEN ISNULL(ErrorColumnTables, 0) > 0 THEN 1 ELSE 0 END),
       @DbsWithRefs    = SUM(CASE WHEN ISNULL(ModuleReferences, 0)  > 0 THEN 1 ELSE 0 END),
       @TableCount     = SUM(ISNULL(QuarantineTables, 0)),
       @ModuleCount    = SUM(ISNULL(ModuleReferences, 0))
FROM #DbScan;

SET @ScannedDbs     = ISNULL(@ScannedDbs, 0);
SET @DbsWithTables  = ISNULL(@DbsWithTables, 0);
SET @DbsWithErrCols = ISNULL(@DbsWithErrCols, 0);
SET @DbsWithRefs    = ISNULL(@DbsWithRefs, 0);
SET @TableCount     = ISNULL(@TableCount, 0);
SET @ModuleCount    = ISNULL(@ModuleCount, 0);

SET @DatabaseQueried = STUFF((SELECT ', ' + DatabaseName
                                FROM #DbScan
                               WHERE QuarantineTables IS NOT NULL
                               ORDER BY DatabaseName
                                 FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '');

SET @Samples = STUFF((SELECT TOP (5) '; ' + DatabaseName + ': ' + SampleObjects
                        FROM #DbScan
                       WHERE SampleObjects IS NOT NULL
                         AND ISNULL(QuarantineTables, 0) > 0
                       ORDER BY DatabaseName
                         FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '');

IF @ScannedDbs = 0 OR @DatabaseQueried IS NULL
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
END
ELSE IF @DbsWithTables > 0 AND @DbsWithRefs > 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'Rejected-row routing is evidenced: ' + CAST(@TableCount AS nvarchar(10))
                   + ' quarantine/error/reject table(s) across ' + CAST(@DbsWithTables AS nvarchar(10)) + ' of '
                   + CAST(@ScannedDbs AS nvarchar(10)) + ' scanned database(s), written to by '
                   + CAST(@ModuleCount AS nvarchar(10)) + ' programmable module(s) in '
                   + CAST(@DbsWithRefs AS nvarchar(10)) + ' database(s). '
                   + CAST(@DbsWithErrCols AS nvarchar(10)) + ' database(s) also expose error-detail columns '
                   + '(ErrorCode/ErrorColumn/ErrorMessage/RejectReason). Examples: ' + ISNULL(@Samples, 'n/a') + '.';
END
ELSE IF @DbsWithTables > 0 OR @DbsWithErrCols > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Partial evidence only: ' + CAST(@TableCount AS nvarchar(10))
                   + ' quarantine/error/reject table(s) in ' + CAST(@DbsWithTables AS nvarchar(10))
                   + ' database(s) and error-detail columns in ' + CAST(@DbsWithErrCols AS nvarchar(10))
                   + ' database(s), but no T-SQL module was found that writes to them (module references: '
                   + CAST(@ModuleCount AS nvarchar(10)) + '). Routing is likely performed by external ETL tooling '
                   + '(SSIS/ADF error outputs) or the tables may be unused. Examples: ' + ISNULL(@Samples, 'n/a')
                   + '. Confirm against the load packages/pipelines.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = 'No quarantine, reject or error landing tables and no error-detail columns '
                   + '(ErrorCode/ErrorColumn/ErrorMessage/RejectReason) were found in any of the '
                   + CAST(@ScannedDbs AS nvarchar(10)) + ' scanned user database(s). '
                   + 'There is no evidence that bad/rejected rows are captured, so they are likely silently dropped or fail the batch.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#DbScan') IS NOT NULL DROP TABLE #DbScan;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;