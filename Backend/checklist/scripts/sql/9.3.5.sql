/*
    Checklist Item : 9.3.5 - Multi-step operations maintain integrity on partial failure
    Area           : Reliability & Resilience
    Purpose        : Inspect user stored procedures that perform multi-step data changes and
                     confirm they wrap the work in an explicit transaction with error handling
                     that rolls the work back when a step fails.
    Safety         : STRICTLY READ-ONLY. Only session #temp tables are written.
    Compatibility  : SQL Server 2012+ and Azure SQL Database (EngineEdition 5).
*/
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#ModuleTxn') IS NOT NULL DROP TABLE #ModuleTxn;
IF OBJECT_ID('tempdb..#ScannedDb') IS NOT NULL DROP TABLE #ScannedDb;
IF OBJECT_ID('tempdb..#Eval') IS NOT NULL DROP TABLE #Eval;

CREATE TABLE #ModuleTxn
(
    DatabaseName SYSNAME       NOT NULL,
    ObjectName   NVARCHAR(600) NOT NULL,
    DmlKinds     INT           NOT NULL,
    HasTran      BIT           NOT NULL,
    HasTryCatch  BIT           NOT NULL,
    HasRollback  BIT           NOT NULL,
    HasXactAbort BIT           NOT NULL
);

CREATE TABLE #ScannedDb
(
    DatabaseName SYSNAME NOT NULL
);

DECLARE @IsAzureSqlDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @Template NVARCHAR(MAX);
DECLARE @Sql      NVARCHAR(MAX);
DECLARE @Db       SYSNAME;
DECLARE @Skipped  INT = 0;

SET @Template = N'
INSERT INTO #ModuleTxn (DatabaseName, ObjectName, DmlKinds, HasTran, HasTryCatch, HasRollback, HasXactAbort)
SELECT
    @DbName,
    QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name),
      CASE WHEN x.d LIKE N''%INSERT %'' THEN 1 ELSE 0 END
    + CASE WHEN x.d LIKE N''%UPDATE %'' THEN 1 ELSE 0 END
    + CASE WHEN x.d LIKE N''%DELETE %'' THEN 1 ELSE 0 END
    + CASE WHEN x.d LIKE N''%MERGE %''  THEN 1 ELSE 0 END,
    CASE WHEN x.d LIKE N''%BEGIN TRAN%'' THEN 1 ELSE 0 END,
    CASE WHEN x.d LIKE N''%BEGIN TRY%'' AND x.d LIKE N''%BEGIN CATCH%'' THEN 1 ELSE 0 END,
    CASE WHEN x.d LIKE N''%ROLLBACK%'' THEN 1 ELSE 0 END,
    CASE WHEN x.d LIKE N''%XACT_ABORT ON%'' THEN 1 ELSE 0 END
FROM {P}sys.sql_modules AS m
INNER JOIN {P}sys.objects AS o ON o.object_id = m.object_id
INNER JOIN {P}sys.schemas AS s ON s.schema_id = o.schema_id
CROSS APPLY (SELECT UPPER(REPLACE(REPLACE(ISNULL(m.definition, N''''), CHAR(13), N'' ''), CHAR(10), N'' '')) AS d) AS x
WHERE o.is_ms_shipped = 0
  AND o.type = ''P'';';

IF @IsAzureSqlDb = 1
BEGIN
    DECLARE @CurrentDb SYSNAME = DB_NAME();

    SET @Sql = REPLACE(@Template, N'{P}', N'');

    BEGIN TRY
        EXEC sp_executesql @Sql, N'@DbName SYSNAME', @DbName = @CurrentDb;
        INSERT INTO #ScannedDb (DatabaseName) VALUES (@CurrentDb);
    END TRY
    BEGIN CATCH
        SET @Skipped = @Skipped + 1;
    END CATCH;
END
ELSE
BEGIN
    DECLARE DbCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.is_in_standby = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN DbCursor;
    FETCH NEXT FROM DbCursor INTO @Db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = REPLACE(@Template, N'{P}', QUOTENAME(@Db) + N'.');

        BEGIN TRY
            EXEC sp_executesql @Sql, N'@DbName SYSNAME', @DbName = @Db;
            INSERT INTO #ScannedDb (DatabaseName) VALUES (@Db);
        END TRY
        BEGIN CATCH
            SET @Skipped = @Skipped + 1;
        END CATCH;

        FETCH NEXT FROM DbCursor INTO @Db;
    END

    CLOSE DbCursor;
    DEALLOCATE DbCursor;
END

SELECT
    DatabaseName,
    ObjectName,
    CASE WHEN DmlKinds >= 2 OR HasTran = 1 THEN 1 ELSE 0 END AS IsCandidate,
    CASE WHEN HasTran = 1
              AND ((HasTryCatch = 1 AND HasRollback = 1) OR HasXactAbort = 1)
         THEN 1 ELSE 0 END AS IsCompliant
INTO #Eval
FROM #ModuleTxn;

DECLARE @DbCount      INT = (SELECT COUNT(*) FROM #ScannedDb);
DECLARE @Total        INT = (SELECT COUNT(*) FROM #Eval WHERE IsCandidate = 1);
DECLARE @Compliant    INT = (SELECT COUNT(*) FROM #Eval WHERE IsCandidate = 1 AND IsCompliant = 1);
DECLARE @NonCompliant INT = 0;
DECLARE @Pct          DECIMAL(5, 2) = 0;

SET @NonCompliant = @Total - @Compliant;
IF @Total > 0
    SET @Pct = CONVERT(DECIMAL(5, 2), (@Compliant * 100.0) / @Total);

DECLARE @Examples NVARCHAR(MAX) =
    STUFF((SELECT TOP (5) N', ' + e.DatabaseName + N'.' + e.ObjectName
           FROM #Eval AS e
           WHERE e.IsCandidate = 1 AND e.IsCompliant = 0
           ORDER BY e.DatabaseName, e.ObjectName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT TOP (10) N', ' + s.DatabaseName
           FROM #ScannedDb AS s
           ORDER BY s.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @DatabaseQueried NVARCHAR(4000) =
    CASE
        WHEN @DbCount = 0 THEN N'None (no accessible user database)'
        WHEN @DbCount > 10 THEN ISNULL(@DbList, N'') + N' (+' + CONVERT(NVARCHAR(20), @DbCount - 10) + N' more)'
        ELSE ISNULL(@DbList, N'')
    END;

DECLARE @Score   INT;
DECLARE @Result  NVARCHAR(10);
DECLARE @Finding NVARCHAR(MAX);

IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No accessible user database could be inspected on this instance'
                 + CASE WHEN @Skipped > 0 THEN N' (' + CONVERT(NVARCHAR(20), @Skipped) + N' database(s) skipped due to permission or state errors)' ELSE N'' END
                 + N'. Transactional integrity of multi-step operations could not be verified and requires manual review.';
END
ELSE IF @Total = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Scanned ' + CONVERT(NVARCHAR(20), @DbCount) + N' user database(s) and found no stored procedure that performs multi-step data changes or opens an explicit transaction. '
                 + N'Server-side transactional integrity for multi-step operations could not be confirmed; if such operations are composed in the application or middle tier, their rollback behaviour must be reviewed manually.'
                 + CASE WHEN @Skipped > 0 THEN N' ' + CONVERT(NVARCHAR(20), @Skipped) + N' database(s) were skipped due to permission or state errors.' ELSE N'' END;
END
ELSE
BEGIN
    SET @Score = CASE
                     WHEN @Pct = 100 THEN 3
                     WHEN @Pct >= 90 THEN 2
                     WHEN @Pct >= 60 THEN 1
                     ELSE 0
                 END;

    SET @Finding = N'Scanned ' + CONVERT(NVARCHAR(20), @DbCount) + N' user database(s) and identified '
                 + CONVERT(NVARCHAR(20), @Total) + N' multi-step stored procedure(s) (two or more DML statement kinds, or an explicit transaction). '
                 + CONVERT(NVARCHAR(20), @Compliant) + N' of these (' + CONVERT(NVARCHAR(20), @Pct) + N'%) protect the work with an explicit transaction plus TRY/CATCH with ROLLBACK or SET XACT_ABORT ON; '
                 + CONVERT(NVARCHAR(20), @NonCompliant) + N' do not and can leave partially applied changes if a step fails.'
                 + CASE WHEN @Examples IS NOT NULL THEN N' Examples: ' + @Examples + N'.' ELSE N'' END
                 + CASE WHEN @Skipped > 0 THEN N' ' + CONVERT(NVARCHAR(20), @Skipped) + N' database(s) were skipped due to permission or state errors.' ELSE N'' END
                 + N' Detection is based on module text analysis of catalog definitions.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#ModuleTxn') IS NOT NULL DROP TABLE #ModuleTxn;
IF OBJECT_ID('tempdb..#ScannedDb') IS NOT NULL DROP TABLE #ScannedDb;
IF OBJECT_ID('tempdb..#Eval') IS NOT NULL DROP TABLE #Eval;