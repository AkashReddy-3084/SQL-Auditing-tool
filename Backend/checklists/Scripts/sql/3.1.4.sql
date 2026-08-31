/* Checklist 3.1.4 - SET NOCOUNT ON and appropriate SET options in procedures
   Read-only: reads catalog views only; writes exclusively to session temp tables. */

SET NOCOUNT ON;

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
IF OBJECT_ID('tempdb..#ProcStats') IS NOT NULL DROP TABLE #ProcStats;
IF OBJECT_ID('tempdb..#Offenders') IS NOT NULL DROP TABLE #Offenders;

CREATE TABLE #Dbs
(
    DatabaseName SYSNAME NOT NULL PRIMARY KEY
);

CREATE TABLE #ProcStats
(
    DatabaseName    SYSNAME NOT NULL,
    TotalProcs      INT     NOT NULL,
    WithNoCount     INT     NOT NULL,
    WithAnsiNulls   INT     NOT NULL,
    WithQuotedIdent INT     NOT NULL,
    CompliantProcs  INT     NOT NULL
);

CREATE TABLE #Offenders
(
    DatabaseName SYSNAME       NOT NULL,
    ProcName     NVARCHAR(300) NOT NULL
);

/* EngineEdition 5 = Azure SQL Database: only the current database is reachable. */
IF @EngineEdition = 5
BEGIN
    INSERT INTO #Dbs (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = N'ONLINE'
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @DbName SYSNAME;
DECLARE @Sql     NVARCHAR(MAX);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Dbs ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
INSERT INTO #ProcStats (DatabaseName, TotalProcs, WithNoCount, WithAnsiNulls, WithQuotedIdent, CompliantProcs)
SELECT
    @db,
    COUNT(*),
    SUM(CASE WHEN x.NormDef LIKE N''%SET NOCOUNT ON%'' THEN 1 ELSE 0 END),
    SUM(CASE WHEN x.uses_ansi_nulls = 1 THEN 1 ELSE 0 END),
    SUM(CASE WHEN x.uses_quoted_identifier = 1 THEN 1 ELSE 0 END),
    SUM(CASE WHEN x.NormDef LIKE N''%SET NOCOUNT ON%''
              AND x.uses_ansi_nulls = 1
              AND x.uses_quoted_identifier = 1 THEN 1 ELSE 0 END)
FROM
(
    SELECT
        m.uses_ansi_nulls,
        m.uses_quoted_identifier,
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            CONVERT(NVARCHAR(MAX), m.definition) COLLATE Latin1_General_CI_AS,
            NCHAR(13), N'' ''), NCHAR(10), N'' ''), NCHAR(9), N'' ''), N''  '', N'' ''), N''  '', N'' '') AS NormDef
    FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m
    INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o
        ON o.object_id = m.object_id
    WHERE o.type = ''P''
      AND o.is_ms_shipped = 0
) AS x
HAVING COUNT(*) > 0;

INSERT INTO #Offenders (DatabaseName, ProcName)
SELECT TOP (5) @db, y.ProcName
FROM
(
    SELECT
        QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name) AS ProcName,
        m.uses_ansi_nulls,
        m.uses_quoted_identifier,
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            CONVERT(NVARCHAR(MAX), m.definition) COLLATE Latin1_General_CI_AS,
            NCHAR(13), N'' ''), NCHAR(10), N'' ''), NCHAR(9), N'' ''), N''  '', N'' ''), N''  '', N'' '') AS NormDef
    FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m
    INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o
        ON o.object_id = m.object_id
    INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s
        ON s.schema_id = o.schema_id
    WHERE o.type = ''P''
      AND o.is_ms_shipped = 0
) AS y
WHERE y.NormDef NOT LIKE N''%SET NOCOUNT ON%''
   OR y.uses_ansi_nulls = 0
   OR y.uses_quoted_identifier = 0
ORDER BY y.ProcName;';

        EXEC sp_executesql @Sql, N'@db SYSNAME', @db = @DbName;
    END TRY
    BEGIN CATCH
        /* Database not readable (offline, restoring, non-readable secondary, no permission) - skip it. */
        SET @Sql = NULL;
    END CATCH;

    FETCH NEXT FROM db_cur INTO @DbName;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @DbCount   INT = (SELECT COUNT(*) FROM #Dbs);
DECLARE @Total     INT = (SELECT ISNULL(SUM(TotalProcs), 0) FROM #ProcStats);
DECLARE @Compliant INT = (SELECT ISNULL(SUM(CompliantProcs), 0) FROM #ProcStats);
DECLARE @NoCountOn INT = (SELECT ISNULL(SUM(WithNoCount), 0) FROM #ProcStats);
DECLARE @AnsiOk    INT = (SELECT ISNULL(SUM(WithAnsiNulls), 0) FROM #ProcStats);
DECLARE @QuotedOk  INT = (SELECT ISNULL(SUM(WithQuotedIdent), 0) FROM #ProcStats);

DECLARE @Pct DECIMAL(5, 2) =
    CASE WHEN @Total = 0 THEN CONVERT(DECIMAL(5, 2), 100)
         ELSE CONVERT(DECIMAL(5, 2), (@Compliant * 100.0) / @Total)
    END;

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #Dbs AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @OffenderList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + o.DatabaseName + N'.' + o.ProcName
           FROM #Offenders AS o
           ORDER BY o.DatabaseName, o.ProcName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Score  INT;
DECLARE @Result NVARCHAR(20);

IF @Total = 0
    SET @Score = 3;
ELSE IF @Pct >= 90.00
    SET @Score = 3;
ELSE IF @Pct >= 60.00
    SET @Score = 2;
ELSE
    SET @Score = 1;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DECLARE @Finding NVARCHAR(MAX) =
    CASE
        WHEN @Total = 0
            THEN N'No user-defined stored procedures were found in ' + CONVERT(NVARCHAR(10), @DbCount)
                 + N' accessible user database(s); SET NOCOUNT ON / SET option compliance is not applicable.'
        ELSE N'Scanned ' + CONVERT(NVARCHAR(10), @DbCount) + N' accessible user database(s) and found '
             + CONVERT(NVARCHAR(10), @Total) + N' user stored procedure(s). '
             + CONVERT(NVARCHAR(10), @NoCountOn) + N' contain SET NOCOUNT ON, '
             + CONVERT(NVARCHAR(10), @AnsiOk) + N' were created with ANSI_NULLS ON, '
             + CONVERT(NVARCHAR(10), @QuotedOk) + N' were created with QUOTED_IDENTIFIER ON. '
             + CONVERT(NVARCHAR(10), @Compliant) + N' of ' + CONVERT(NVARCHAR(10), @Total) + N' ('
             + CONVERT(NVARCHAR(20), @Pct) + N'%) satisfy all three requirements.'
             + CASE WHEN @OffenderList IS NULL THEN N''
                    ELSE N' Examples of non-compliant procedures: ' + @OffenderList + N'.'
               END
    END;

SELECT
    @Result AS Result,
    @Score  AS Score,
    ISNULL(@DbList, N'None') AS DatabaseQueried,
    @Finding AS Finding;

IF OBJECT_ID('tempdb..#Offenders') IS NOT NULL DROP TABLE #Offenders;
IF OBJECT_ID('tempdb..#ProcStats') IS NOT NULL DROP TABLE #ProcStats;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;