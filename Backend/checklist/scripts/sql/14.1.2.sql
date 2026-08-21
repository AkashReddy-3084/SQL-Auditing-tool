SET NOCOUNT ON;

/* 14.1.2 - SARGable predicates: detects function-wrapped predicates and leading-wildcard LIKE in stored module text. Read-only. */

IF OBJECT_ID('tempdb..#Scanned') IS NOT NULL DROP TABLE #Scanned;
IF OBJECT_ID('tempdb..#NonSargable') IS NOT NULL DROP TABLE #NonSargable;

CREATE TABLE #Scanned
(
    DatabaseName SYSNAME NOT NULL
);

CREATE TABLE #NonSargable
(
    DatabaseName SYSNAME       NOT NULL,
    SchemaName   SYSNAME       NOT NULL,
    ObjectName   SYSNAME       NOT NULL,
    ObjectType   NVARCHAR(60)  NULL,
    PatternFound NVARCHAR(200) NOT NULL
);

DECLARE @IsAzureDb BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @Template  NVARCHAR(MAX);
DECLARE @Sql       NVARCHAR(MAX);
DECLARE @DbName    SYSNAME;

SET @Template = N'
INSERT INTO #NonSargable (DatabaseName, SchemaName, ObjectName, ObjectType, PatternFound)
SELECT DISTINCT @@DBNAME@@, s.name, o.name, o.type_desc, p.PatternFound
FROM @@PREFIX@@sys.sql_modules AS m
INNER JOIN @@PREFIX@@sys.objects AS o
        ON o.object_id = m.object_id
INNER JOIN @@PREFIX@@sys.schemas AS s
        ON s.schema_id = o.schema_id
CROSS APPLY
(
    SELECT UPPER(
               REPLACE(REPLACE(REPLACE(
                   REPLACE(REPLACE(REPLACE(m.definition, CHAR(13), N'' ''), CHAR(10), N'' ''), CHAR(9), N'' ''),
                   N''  '', N'' ''), N''  '', N'' ''), N''  '', N'' '')) AS Def
) AS d
CROSS APPLY
(
    SELECT k.Kw + f.Fn AS PatternFound,
           N''%'' + k.Kw + f.Fn + N''%'' AS SearchExpr
    FROM (VALUES (N''WHERE ''), (N''AND ''), (N''OR ''), (N''ON '')) AS k(Kw)
    CROSS JOIN (VALUES
        (N''UPPER(''), (N''LOWER(''), (N''LTRIM(''), (N''RTRIM(''), (N''ISNULL(''),
        (N''COALESCE(''), (N''CONVERT(''), (N''CAST(''), (N''YEAR(''), (N''MONTH(''),
        (N''DAY(''), (N''DATEPART(''), (N''DATEDIFF(''), (N''DATEADD(''), (N''LEFT(''),
        (N''RIGHT(''), (N''SUBSTRING(''), (N''REPLACE(''), (N''FLOOR(''), (N''ROUND(''),
        (N''ABS(''), (N''LEN('')) AS f(Fn)
    UNION ALL
    SELECT N''LIKE with leading wildcard'', N''%LIKE ''''[%]%''
) AS p
WHERE o.is_ms_shipped = 0
  AND o.type IN (''P'', ''V'', ''FN'', ''IF'', ''TF'', ''TR'')
  AND d.Def LIKE p.SearchExpr;
';

IF @IsAzureDb = 1
BEGIN
    SET @DbName = DB_NAME();

    INSERT INTO #Scanned (DatabaseName) VALUES (@DbName);

    SET @Sql = REPLACE(REPLACE(@Template, N'@@PREFIX@@', N''),
                       N'@@DBNAME@@', N'N' + QUOTENAME(@DbName, ''''));

    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        /* database not readable - leave it out of the findings */
    END CATCH
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT INTO #Scanned (DatabaseName) VALUES (@DbName);

            SET @Sql = REPLACE(REPLACE(@Template, N'@@PREFIX@@', QUOTENAME(@DbName) + N'.'),
                               N'@@DBNAME@@', N'N' + QUOTENAME(@DbName, ''''));

            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            /* database not readable - leave it out of the findings */
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @DbCount         INT = (SELECT COUNT(*) FROM #Scanned);
DECLARE @AffectedDbs     INT = (SELECT COUNT(DISTINCT DatabaseName) FROM #NonSargable);
DECLARE @AffectedObjects INT =
(
    SELECT COUNT(*)
    FROM (SELECT DISTINCT DatabaseName, SchemaName, ObjectName FROM #NonSargable) AS x
);

DECLARE @DbList NVARCHAR(MAX);
SELECT @DbList = STUFF(
    (SELECT N', ' + sc.DatabaseName
     FROM #Scanned AS sc
     ORDER BY sc.DatabaseName
     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Examples NVARCHAR(MAX);
SELECT @Examples = STUFF(
    (SELECT TOP (5) N'; ' + t.DatabaseName + N'.' + t.SchemaName + N'.' + t.ObjectName + N' [' + t.PatternFound + N']'
     FROM (SELECT DISTINCT DatabaseName, SchemaName, ObjectName, PatternFound FROM #NonSargable) AS t
     ORDER BY t.DatabaseName, t.SchemaName, t.ObjectName
     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Score INT;
DECLARE @Result NVARCHAR(10);
DECLARE @Finding NVARCHAR(MAX);

SET @Score =
    CASE
        WHEN @DbCount = 0            THEN 0
        WHEN @AffectedObjects = 0    THEN 3
        WHEN @AffectedObjects <= 5   THEN 2
        WHEN @AffectedObjects <= 20  THEN 1
        ELSE 0
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
    CASE
        WHEN @DbCount = 0
            THEN N'No accessible user database could be scanned, so SARGability of predicates could not be assessed.'
        WHEN @AffectedObjects = 0
            THEN N'Scanned ' + CAST(@DbCount AS NVARCHAR(10))
                 + N' user database(s); no programmable object applies a scalar function directly to a predicate column after WHERE/AND/OR/ON and none uses a leading-wildcard LIKE. Predicates appear SARGable.'
        ELSE N'Scanned ' + CAST(@DbCount AS NVARCHAR(10)) + N' user database(s); '
             + CAST(@AffectedObjects AS NVARCHAR(10)) + N' programmable object(s) across '
             + CAST(@AffectedDbs AS NVARCHAR(10))
             + N' database(s) contain non-SARGable predicate patterns (scalar function applied to a predicate column, or leading-wildcard LIKE). Examples: '
             + LEFT(ISNULL(@Examples, N'n/a'), 2000) + N'.'
    END;

SELECT
    @Result                              AS Result,
    @Score                               AS Score,
    LEFT(ISNULL(@DbList, N'None'), 3900) AS DatabaseQueried,
    @Finding                             AS Finding;

IF OBJECT_ID('tempdb..#Scanned') IS NOT NULL DROP TABLE #Scanned;
IF OBJECT_ID('tempdb..#NonSargable') IS NOT NULL DROP TABLE #NonSargable;