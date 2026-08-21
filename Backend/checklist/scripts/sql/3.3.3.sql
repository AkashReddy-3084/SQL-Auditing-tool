/* Checklist 3.3.3 - XACT_ABORT / transaction state handling correct on error
   Read-only: inspects module definitions in sys.sql_modules across accessible user databases. */
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#ScannedDatabases') IS NOT NULL DROP TABLE #ScannedDatabases;
IF OBJECT_ID('tempdb..#TxnModules') IS NOT NULL DROP TABLE #TxnModules;

CREATE TABLE #ScannedDatabases (DatabaseName SYSNAME NOT NULL);

CREATE TABLE #TxnModules
(
    DatabaseName SYSNAME NOT NULL,
    SchemaName   SYSNAME NOT NULL,
    ObjectName   SYSNAME NOT NULL,
    ObjectType   NVARCHAR(60) NOT NULL,
    HasXactAbort BIT NOT NULL,
    HasTryCatch  BIT NOT NULL,
    HasRollback  BIT NOT NULL,
    HasXactState BIT NOT NULL
);

DECLARE @IsAzureSqlDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

IF @IsAzureSqlDb = 1
BEGIN
    SET @DbName = DB_NAME();

    INSERT INTO #ScannedDatabases (DatabaseName) VALUES (@DbName);

    INSERT INTO #TxnModules (DatabaseName, SchemaName, ObjectName, ObjectType, HasXactAbort, HasTryCatch, HasRollback, HasXactState)
    SELECT @DbName,
           s.name,
           o.name,
           o.type_desc,
           CASE WHEN d.NormalizedDefinition LIKE '%XACT_ABORT ON%' THEN 1 ELSE 0 END,
           CASE WHEN d.NormalizedDefinition LIKE '%BEGIN TRY%' AND d.NormalizedDefinition LIKE '%BEGIN CATCH%' THEN 1 ELSE 0 END,
           CASE WHEN d.NormalizedDefinition LIKE '%ROLLBACK%' THEN 1 ELSE 0 END,
           CASE WHEN d.NormalizedDefinition LIKE '%XACT_STATE%' THEN 1 ELSE 0 END
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o ON o.object_id = m.object_id
    INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
    CROSS APPLY (
        SELECT UPPER(REPLACE(REPLACE(REPLACE(m.definition, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ')) AS NormalizedDefinition
    ) AS d
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('P', 'TR')
      AND (d.NormalizedDefinition LIKE '%BEGIN TRAN%' OR d.NormalizedDefinition LIKE '%BEGIN DISTRIBUTED TRAN%');
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'
        INSERT INTO #TxnModules (DatabaseName, SchemaName, ObjectName, ObjectType, HasXactAbort, HasTryCatch, HasRollback, HasXactState)
        SELECT ' + QUOTENAME(@DbName, '''') + N',
               s.name,
               o.name,
               o.type_desc,
               CASE WHEN d.NormalizedDefinition LIKE ''%XACT_ABORT ON%'' THEN 1 ELSE 0 END,
               CASE WHEN d.NormalizedDefinition LIKE ''%BEGIN TRY%'' AND d.NormalizedDefinition LIKE ''%BEGIN CATCH%'' THEN 1 ELSE 0 END,
               CASE WHEN d.NormalizedDefinition LIKE ''%ROLLBACK%'' THEN 1 ELSE 0 END,
               CASE WHEN d.NormalizedDefinition LIKE ''%XACT_STATE%'' THEN 1 ELSE 0 END
        FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m
        INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o ON o.object_id = m.object_id
        INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = o.schema_id
        CROSS APPLY (
            SELECT UPPER(REPLACE(REPLACE(REPLACE(m.definition, CHAR(13), '' ''), CHAR(10), '' ''), CHAR(9), '' '')) AS NormalizedDefinition
        ) AS d
        WHERE o.is_ms_shipped = 0
          AND o.type IN (''P'', ''TR'')
          AND (d.NormalizedDefinition LIKE ''%BEGIN TRAN%'' OR d.NormalizedDefinition LIKE ''%BEGIN DISTRIBUTED TRAN%'');';

        BEGIN TRY
            EXEC sp_executesql @Sql;
            INSERT INTO #ScannedDatabases (DatabaseName) VALUES (@DbName);
        END TRY
        BEGIN CATCH
            /* Database not readable by this login - skip it */
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @DatabasesScanned INT = (SELECT COUNT(*) FROM #ScannedDatabases);
DECLARE @TotalModules INT = 0;
DECLARE @CompliantModules INT = 0;

SELECT @TotalModules = COUNT(*),
       @CompliantModules = SUM(CASE WHEN HasXactAbort = 1
                                      OR (HasTryCatch = 1 AND (HasRollback = 1 OR HasXactState = 1))
                                    THEN 1 ELSE 0 END)
FROM #TxnModules;

SET @TotalModules = ISNULL(@TotalModules, 0);
SET @CompliantModules = ISNULL(@CompliantModules, 0);

DECLARE @NonCompliantModules INT = @TotalModules - @CompliantModules;
DECLARE @CompliancePct DECIMAL(5, 1) =
    CASE WHEN @TotalModules = 0 THEN 100.0
         ELSE CONVERT(DECIMAL(5, 1), (@CompliantModules * 100.0) / @TotalModules) END;

DECLARE @DatabaseQueried NVARCHAR(MAX) =
    STUFF((SELECT ', ' + sd.DatabaseName
           FROM #ScannedDatabases AS sd
           ORDER BY sd.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

DECLARE @SampleOffenders NVARCHAR(MAX) =
    STUFF((SELECT TOP (10) '; ' + t.DatabaseName + '.' + t.SchemaName + '.' + t.ObjectName
           FROM #TxnModules AS t
           WHERE t.HasXactAbort = 0
             AND NOT (t.HasTryCatch = 1 AND (t.HasRollback = 1 OR t.HasXactState = 1))
           ORDER BY t.DatabaseName, t.SchemaName, t.ObjectName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

DECLARE @Score INT;
DECLARE @Result NVARCHAR(20);
DECLARE @Finding NVARCHAR(MAX);

IF @DatabasesScanned = 0
BEGIN
    SET @Score = 0;
    SET @Result = 'FAIL';
    SET @Finding = 'No accessible user databases were found, so transaction/error-handling patterns could not be inspected.';
END
ELSE IF @TotalModules = 0
BEGIN
    SET @Score = 3;
    SET @Result = 'PASS';
    SET @Finding = 'No user stored procedures or triggers open explicit transactions across ' + CONVERT(NVARCHAR(10), @DatabasesScanned)
                 + ' database(s); there is no unprotected transaction/error-handling exposure.';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @CompliancePct = 100.0 THEN 3
                      WHEN @CompliancePct >= 80.0 THEN 2
                      WHEN @CompliancePct >= 50.0 THEN 1
                      ELSE 0 END;
    SET @Result = CASE WHEN @Score = 3 THEN 'PASS' ELSE 'FAIL' END;
    SET @Finding = CONVERT(NVARCHAR(10), @CompliantModules) + ' of ' + CONVERT(NVARCHAR(10), @TotalModules)
                 + ' transactional module(s) across ' + CONVERT(NVARCHAR(10), @DatabasesScanned)
                 + ' database(s) (' + CONVERT(NVARCHAR(10), @CompliancePct)
                 + '%) set XACT_ABORT ON or use TRY/CATCH with ROLLBACK or XACT_STATE().'
                 + CASE WHEN @NonCompliantModules > 0
                        THEN ' ' + CONVERT(NVARCHAR(10), @NonCompliantModules)
                             + ' module(s) open a transaction without correct error/transaction-state handling. Examples: '
                             + ISNULL(@SampleOffenders, 'n/a') + '.'
                        ELSE '' END;
END

SELECT @Result AS Result,
       @Score AS Score,
       ISNULL(@DatabaseQueried, 'None') AS DatabaseQueried,
       @Finding AS Finding;

IF OBJECT_ID('tempdb..#TxnModules') IS NOT NULL DROP TABLE #TxnModules;
IF OBJECT_ID('tempdb..#ScannedDatabases') IS NOT NULL DROP TABLE #ScannedDatabases;