SET NOCOUNT ON;

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @IsAzureSqlDb bit = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#AuditDbs') IS NOT NULL DROP TABLE #AuditDbs;
CREATE TABLE #AuditDbs (DatabaseName sysname NOT NULL PRIMARY KEY);

IF OBJECT_ID('tempdb..#Modules') IS NOT NULL DROP TABLE #Modules;
CREATE TABLE #Modules
(
    DatabaseName   sysname       NOT NULL,
    SchemaName     sysname       NOT NULL,
    ModuleName     sysname       NOT NULL,
    ModuleType     nvarchar(60)  NOT NULL,
    DmlStatements  int           NOT NULL,
    HasTransaction bit           NOT NULL,
    HasTryCatch    bit           NOT NULL,
    HasRollback    bit           NOT NULL,
    HasXactAbort   bit           NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #AuditDbs (DatabaseName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #AuditDbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_in_standby = 0
      AND d.source_database_id IS NULL
      AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db sysname;
DECLARE @prefix nvarchar(300);
DECLARE @sql nvarchar(max);
DECLARE @SkippedDbs int = 0;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #AuditDbs ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

    SET @sql = N'
INSERT INTO #Modules (DatabaseName, SchemaName, ModuleName, ModuleType, DmlStatements, HasTransaction, HasTryCatch, HasRollback, HasXactAbort)
SELECT ' + QUOTENAME(@db, '''') + N' AS DatabaseName,
       s.name AS SchemaName,
       o.name AS ModuleName,
       o.type_desc AS ModuleType,
       CAST(c.Ins + c.Upd + c.Del + c.Mrg AS int) AS DmlStatements,
       CASE WHEN n.d LIKE N''%BEGIN TRAN%'' THEN 1 ELSE 0 END AS HasTransaction,
       CASE WHEN n.d LIKE N''%BEGIN TRY%'' AND n.d LIKE N''%BEGIN CATCH%'' THEN 1 ELSE 0 END AS HasTryCatch,
       CASE WHEN n.d LIKE N''%ROLLBACK%'' THEN 1 ELSE 0 END AS HasRollback,
       CASE WHEN n.d LIKE N''%SET XACT_ABORT ON%'' THEN 1 ELSE 0 END AS HasXactAbort
FROM ' + @prefix + N'sys.sql_modules AS m
INNER JOIN ' + @prefix + N'sys.objects AS o
        ON o.object_id = m.object_id
INNER JOIN ' + @prefix + N'sys.schemas AS s
        ON s.schema_id = o.schema_id
CROSS APPLY (SELECT d0 = UPPER(REPLACE(REPLACE(REPLACE(m.definition, NCHAR(13), N'' ''), NCHAR(10), N'' ''), NCHAR(9), N'' ''))) AS a
CROSS APPLY (SELECT d = REPLACE(REPLACE(REPLACE(REPLACE(a.d0, N''  '', N'' ''), N''  '', N'' ''), N''  '', N'' ''), N''  '', N'' '')) AS n
CROSS APPLY (SELECT
        Ins = (DATALENGTH(n.d) - DATALENGTH(REPLACE(n.d, N''INSERT '', N''''))) / 14,
        Upd = (DATALENGTH(n.d) - DATALENGTH(REPLACE(n.d, N''UPDATE '', N''''))) / 14,
        Del = (DATALENGTH(n.d) - DATALENGTH(REPLACE(n.d, N''DELETE '', N''''))) / 14,
        Mrg = (DATALENGTH(n.d) - DATALENGTH(REPLACE(n.d, N''MERGE '', N''''))) / 12) AS c
WHERE o.is_ms_shipped = 0
  AND o.type IN (N''P'', N''TR'')
  AND m.definition IS NOT NULL;';

    BEGIN TRY
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @SkippedDbs = @SkippedDbs + 1;
    END CATCH

    FETCH NEXT FROM db_cursor INTO @db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @DbCount int = (SELECT COUNT(*) FROM #AuditDbs);

DECLARE @DbList nvarchar(max) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #AuditDbs AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(N''), TYPE).value(N'.[1]', N'nvarchar(max)'), 1, 2, N'');

DECLARE @TotalModules int = (SELECT COUNT(*) FROM #Modules);
DECLARE @MultiStep int = 0;
DECLARE @Protected int = 0;

SELECT @MultiStep = COUNT(*),
       @Protected = SUM(CASE
                            WHEN m.HasTransaction = 1
                             AND ((m.HasTryCatch = 1 AND m.HasRollback = 1) OR m.HasXactAbort = 1)
                            THEN 1 ELSE 0
                        END)
FROM #Modules AS m
WHERE m.DmlStatements >= 2
   OR m.HasTransaction = 1;

SET @MultiStep = ISNULL(@MultiStep, 0);
SET @Protected = ISNULL(@Protected, 0);

DECLARE @Unprotected int = @MultiStep - @Protected;

DECLARE @Offenders nvarchar(max) =
    STUFF((SELECT TOP (5) N'; ' + t.DatabaseName + N'.' + t.SchemaName + N'.' + t.ModuleName
                          + N' (' + CAST(t.DmlStatements AS nvarchar(10)) + N' DML, TRAN='
                          + CAST(t.HasTransaction AS nvarchar(1)) + N', TRY/CATCH='
                          + CAST(t.HasTryCatch AS nvarchar(1)) + N', ROLLBACK='
                          + CAST(t.HasRollback AS nvarchar(1)) + N', XACT_ABORT='
                          + CAST(t.HasXactAbort AS nvarchar(1)) + N')'
           FROM #Modules AS t
           WHERE (t.DmlStatements >= 2 OR t.HasTransaction = 1)
             AND NOT (t.HasTransaction = 1 AND ((t.HasTryCatch = 1 AND t.HasRollback = 1) OR t.HasXactAbort = 1))
           ORDER BY t.DmlStatements DESC, t.DatabaseName, t.SchemaName, t.ModuleName
           FOR XML PATH(N''), TYPE).value(N'.[1]', N'nvarchar(max)'), 1, 2, N'');

DECLARE @Pct decimal(9,2) =
    CASE WHEN @MultiStep = 0 THEN CAST(100.00 AS decimal(9,2))
         ELSE CAST(100.0 * @Protected / @MultiStep AS decimal(9,2))
    END;

DECLARE @Score int;
DECLARE @Result nvarchar(20);
DECLARE @DatabaseQueried nvarchar(max);
DECLARE @Finding nvarchar(max);

SET @Score =
    CASE WHEN @DbCount = 0 THEN 0
         WHEN @MultiStep = 0 THEN 3
         WHEN @Pct >= 100.00 THEN 3
         WHEN @Pct >= 90.00 THEN 2
         WHEN @Pct >= 60.00 THEN 1
         ELSE 0
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @DatabaseQueried = ISNULL(@DbList, N'None');

SET @Finding =
    CASE
        WHEN @DbCount = 0
            THEN N'No accessible user database could be inspected on this instance, so transaction consistency of multi-step operations could not be evaluated.'
        WHEN @MultiStep = 0
            THEN N'Inspected ' + CAST(@TotalModules AS nvarchar(10)) + N' user stored procedure(s)/DML trigger(s) across '
                 + CAST(@DbCount AS nvarchar(10)) + N' database(s); none perform multi-step data modifications, so no partial-failure exposure exists.'
        WHEN @Unprotected = 0
            THEN N'All ' + CAST(@MultiStep AS nvarchar(10)) + N' multi-step module(s) across ' + CAST(@DbCount AS nvarchar(10))
                 + N' database(s) wrap their work in an explicit transaction with TRY/CATCH + ROLLBACK or SET XACT_ABORT ON (100.00% protected).'
        ELSE N'Of ' + CAST(@MultiStep AS nvarchar(10)) + N' multi-step module(s) across ' + CAST(@DbCount AS nvarchar(10))
             + N' database(s), ' + CAST(@Unprotected AS nvarchar(10)) + N' lack transaction-based failure protection ('
             + CAST(@Pct AS nvarchar(10)) + N'% protected). Examples: ' + ISNULL(@Offenders, N'n/a') + N'.'
    END
    + CASE WHEN @SkippedDbs > 0
           THEN N' ' + CAST(@SkippedDbs AS nvarchar(10)) + N' database(s) were skipped because their metadata could not be read.'
           ELSE N'' END;

IF OBJECT_ID('tempdb..#Modules') IS NOT NULL DROP TABLE #Modules;
IF OBJECT_ID('tempdb..#AuditDbs') IS NOT NULL DROP TABLE #AuditDbs;

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;