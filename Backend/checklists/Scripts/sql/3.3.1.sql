/* Checklist 3.3.1 - Transactions scoped correctly (not held open across long operations)
   Read-only. Inspects module definitions in every accessible user database. */
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#TxnModules') IS NOT NULL DROP TABLE #TxnModules;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;

CREATE TABLE #TxnModules
(
    DatabaseName  sysname       NOT NULL,
    SchemaName    sysname       NULL,
    ObjectName    sysname       NOT NULL,
    ObjectType    nvarchar(60)  NULL,
    BeginCount    int           NOT NULL,
    CommitCount   int           NOT NULL,
    RollbackCount int           NOT NULL,
    HasTryCatch   bit           NOT NULL,
    HasXactAbort  bit           NOT NULL,
    LongOpPattern nvarchar(400) NULL
);

CREATE TABLE #Dbs (DatabaseName sysname NOT NULL PRIMARY KEY);

DECLARE @IsAzureDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;
DECLARE @Scanned int = 0;
DECLARE @Skipped int = 0;

IF @IsAzureDb = 1
BEGIN
    INSERT INTO #Dbs (DatabaseName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.name <> 'distribution'
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @Body nvarchar(max) = N'
INSERT INTO #TxnModules
    (DatabaseName, SchemaName, ObjectName, ObjectType, BeginCount, CommitCount, RollbackCount, HasTryCatch, HasXactAbort, LongOpPattern)
SELECT DB_NAME(),
       SCHEMA_NAME(o.schema_id),
       o.name,
       o.type_desc,
       CAST((DATALENGTH(d.def) - DATALENGTH(REPLACE(d.def, N''BEGIN TRAN'', N''''))) / 20 AS int),
       CAST((DATALENGTH(d.def) - DATALENGTH(REPLACE(d.def, N''COMMIT'', N''''))) / 12 AS int),
       CAST((DATALENGTH(d.def) - DATALENGTH(REPLACE(d.def, N''ROLLBACK'', N''''))) / 16 AS int),
       CASE WHEN d.def LIKE N''%BEGIN TRY%'' THEN 1 ELSE 0 END,
       CASE WHEN d.def LIKE N''%XACT_ABORT ON%'' THEN 1 ELSE 0 END,
       CAST(
            CASE WHEN d.def LIKE N''%WAITFOR DELAY%'' THEN N''WAITFOR DELAY; '' ELSE N'''' END
          + CASE WHEN d.def LIKE N''%WAITFOR TIME%'' THEN N''WAITFOR TIME; '' ELSE N'''' END
          + CASE WHEN d.def LIKE N''%BACKUP DATABASE%'' OR d.def LIKE N''%BACKUP LOG%'' THEN N''BACKUP; '' ELSE N'''' END
          + CASE WHEN d.def LIKE N''%DBCC %'' THEN N''DBCC; '' ELSE N'''' END
          + CASE WHEN d.def LIKE N''%ALTER INDEX%'' THEN N''ALTER INDEX; '' ELSE N'''' END
          + CASE WHEN d.def LIKE N''% CURSOR %'' OR d.def LIKE N''%FETCH NEXT%'' THEN N''CURSOR loop; '' ELSE N'''' END
          + CASE WHEN d.def LIKE N''%WHILE %'' THEN N''WHILE loop; '' ELSE N'''' END
          + CASE WHEN d.def LIKE N''%sp_send_dbmail%'' THEN N''sp_send_dbmail; '' ELSE N'''' END
          + CASE WHEN d.def LIKE N''%xp_cmdshell%'' THEN N''xp_cmdshell; '' ELSE N'''' END
          + CASE WHEN d.def LIKE N''%OPENQUERY%'' OR d.def LIKE N''%OPENROWSET%'' OR d.def LIKE N''%OPENDATASOURCE%'' THEN N''Distributed query; '' ELSE N'''' END
          + CASE WHEN d.def LIKE N''%sp_OACreate%'' THEN N''OLE automation; '' ELSE N'''' END
       AS nvarchar(400))
FROM sys.sql_modules AS m
INNER JOIN sys.objects AS o ON o.object_id = m.object_id
CROSS APPLY (SELECT CAST(m.definition AS nvarchar(max)) COLLATE Latin1_General_CI_AS AS def) AS d
WHERE o.is_ms_shipped = 0
  AND o.type IN (N''P'', N''PC'', N''TR'', N''FN'', N''TF'', N''IF'')
  AND d.def LIKE N''%BEGIN TRAN%'';';

DECLARE @Db sysname;
DECLARE @Sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Dbs ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE N'USE ' + QUOTENAME(@Db) + N'; ' END + @Body;
        EXEC sys.sp_executesql @Sql;
        SET @Scanned = @Scanned + 1;
    END TRY
    BEGIN CATCH
        SET @Skipped = @Skipped + 1;
    END CATCH

    FETCH NEXT FROM db_cur INTO @Db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @TotalTxn   int = (SELECT COUNT(*) FROM #TxnModules);
DECLARE @Unbalanced int = (SELECT COUNT(*) FROM #TxnModules WHERE BeginCount > CommitCount);
DECLARE @LongOp     int = (SELECT COUNT(*) FROM #TxnModules WHERE LTRIM(RTRIM(ISNULL(LongOpPattern, N''))) <> N'');
DECLARE @NoGuard    int = (SELECT COUNT(*) FROM #TxnModules WHERE HasTryCatch = 0 AND HasXactAbort = 0);
DECLARE @Risky      int = (SELECT COUNT(*) FROM #TxnModules
                           WHERE BeginCount > CommitCount
                              OR LTRIM(RTRIM(ISNULL(LongOpPattern, N''))) <> N''
                              OR (HasTryCatch = 0 AND HasXactAbort = 0));

DECLARE @Pct decimal(9,2) = CASE WHEN @TotalTxn = 0 THEN 0.00 ELSE (@Risky * 100.0) / @TotalTxn END;

DECLARE @DbList nvarchar(max) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #Dbs AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @Examples nvarchar(max) =
    STUFF((SELECT TOP (5) N'; ' + t.DatabaseName + N'.' + ISNULL(t.SchemaName, N'?') + N'.' + t.ObjectName
                  + N' (' + LTRIM(RTRIM(
                        CASE WHEN t.BeginCount > t.CommitCount THEN N'unclosed BEGIN TRAN; ' ELSE N'' END
                      + ISNULL(t.LongOpPattern, N'')
                      + CASE WHEN t.HasTryCatch = 0 AND t.HasXactAbort = 0 THEN N'no TRY/CATCH or XACT_ABORT; ' ELSE N'' END)) + N')'
           FROM #TxnModules AS t
           WHERE t.BeginCount > t.CommitCount
              OR LTRIM(RTRIM(ISNULL(t.LongOpPattern, N''))) <> N''
              OR (t.HasTryCatch = 0 AND t.HasXactAbort = 0)
           ORDER BY t.DatabaseName, t.SchemaName, t.ObjectName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @Result  nvarchar(20);
DECLARE @Score   int;
DECLARE @Finding nvarchar(max);

IF @Scanned = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No user database could be scanned (none present, offline, or no VIEW DEFINITION permission). '
                 + CAST(@Skipped AS nvarchar(10)) + N' database(s) skipped due to errors. Transaction scoping in T-SQL code could not be assessed.';
END
ELSE IF @TotalTxn = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Scanned ' + CAST(@Scanned AS nvarchar(10)) + N' database(s); no user procedure, trigger or function uses explicit BEGIN TRANSACTION, so no long-held explicit transaction scope exists in T-SQL code.'
                 + CASE WHEN @Skipped > 0 THEN N' ' + CAST(@Skipped AS nvarchar(10)) + N' database(s) were inaccessible and not assessed.' ELSE N'' END;
END
ELSE
BEGIN
    SET @Score = CASE
                     WHEN @Risky = 0 THEN 3
                     WHEN @Pct <= 10.00 THEN 2
                     WHEN @Pct <= 30.00 THEN 1
                     ELSE 0
                 END;

    SET @Finding = N'Scanned ' + CAST(@Scanned AS nvarchar(10)) + N' database(s). '
                 + CAST(@TotalTxn AS nvarchar(10)) + N' module(s) use explicit transactions; '
                 + CAST(@Risky AS nvarchar(10)) + N' (' + CAST(@Pct AS nvarchar(10)) + N'%) have transaction-scoping risks: '
                 + CAST(@Unbalanced AS nvarchar(10)) + N' with more BEGIN TRAN than COMMIT, '
                 + CAST(@LongOp AS nvarchar(10)) + N' containing long-running/blocking operations inside the transaction, '
                 + CAST(@NoGuard AS nvarchar(10)) + N' without TRY/CATCH or SET XACT_ABORT ON.'
                 + CASE WHEN @Examples IS NULL THEN N'' ELSE N' Examples: ' + @Examples + N'.' END
                 + CASE WHEN @Skipped > 0 THEN N' ' + CAST(@Skipped AS nvarchar(10)) + N' database(s) were inaccessible and not assessed.' ELSE N'' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result                 AS Result,
       @Score                  AS Score,
       ISNULL(@DbList, N'N/A') AS DatabaseQueried,
       @Finding                AS Finding;

IF OBJECT_ID('tempdb..#TxnModules') IS NOT NULL DROP TABLE #TxnModules;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;