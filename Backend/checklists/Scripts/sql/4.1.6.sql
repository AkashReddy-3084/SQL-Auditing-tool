SET NOCOUNT ON;

/* Checklist 4.1.6 - Schemas used to organize objects by layer/domain
   Strictly read-only; only temp tables are written. */

DECLARE @Result          NVARCHAR(20);
DECLARE @Score           INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding         NVARCHAR(MAX);

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF OBJECT_ID('tempdb..#SchemaOrg') IS NOT NULL
    DROP TABLE #SchemaOrg;

CREATE TABLE #SchemaOrg
(
    DatabaseName           SYSNAME        NOT NULL,
    UserSchemaCount        INT            NULL,
    UserSchemasWithObjects INT            NULL,
    TotalObjects           INT            NULL,
    ObjectsInDbo           INT            NULL,
    ObjectsInUserSchemas   INT            NULL,
    SchemaList             NVARCHAR(1000) NULL,
    IsPlaceholder          BIT            NOT NULL DEFAULT (0)
);

DECLARE @Template NVARCHAR(MAX) = N'
INSERT INTO #SchemaOrg
    (DatabaseName, UserSchemaCount, UserSchemasWithObjects, TotalObjects,
     ObjectsInDbo, ObjectsInUserSchemas, SchemaList, IsPlaceholder)
SELECT
    @dbname,
    (SELECT COUNT(*)
       FROM {DB}sys.schemas AS s1
      WHERE s1.schema_id < 16384
        AND s1.name NOT IN (''dbo'', ''sys'', ''guest'', ''INFORMATION_SCHEMA'')),
    COUNT(DISTINCT CASE WHEN sc.name <> ''dbo'' THEN sc.name END),
    COUNT(*),
    SUM(CASE WHEN sc.name = ''dbo'' THEN 1 ELSE 0 END),
    SUM(CASE WHEN sc.name <> ''dbo'' THEN 1 ELSE 0 END),
    (SELECT STUFF((SELECT TOP (15) N'', '' + s3.name
                     FROM {DB}sys.schemas AS s3
                    WHERE s3.schema_id < 16384
                      AND s3.name NOT IN (''dbo'', ''sys'', ''guest'', ''INFORMATION_SCHEMA'')
                    ORDER BY s3.name
                      FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(1000)''), 1, 2, N'''')),
    0
FROM {DB}sys.objects AS o
INNER JOIN {DB}sys.schemas AS sc
        ON sc.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'', ''SN'')
  AND o.name <> ''sysdiagrams'';';

DECLARE @sql NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: cross-database queries are unavailable, evaluate the current database only. */
    DECLARE @CurrentDb SYSNAME = DB_NAME();

    SET @sql = REPLACE(@Template, N'{DB}', N'');

    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@dbname SYSNAME', @dbname = @CurrentDb;
    END TRY
    BEGIN CATCH
        INSERT INTO #SchemaOrg
            (DatabaseName, UserSchemaCount, UserSchemasWithObjects, TotalObjects,
             ObjectsInDbo, ObjectsInUserSchemas, SchemaList, IsPlaceholder)
        VALUES (@CurrentDb, NULL, NULL, NULL, NULL, NULL, NULL, 1);
    END CATCH
END
ELSE
BEGIN
    DECLARE @db SYSNAME;

    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
          FROM sys.databases AS d
         WHERE d.database_id > 4
           AND d.state_desc = 'ONLINE'
           AND d.source_database_id IS NULL
           AND d.is_in_standby = 0
           AND HAS_DBACCESS(d.name) = 1
         ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = REPLACE(@Template, N'{DB}', QUOTENAME(@db) + N'.');

        BEGIN TRY
            EXEC sys.sp_executesql @sql, N'@dbname SYSNAME', @dbname = @db;
        END TRY
        BEGIN CATCH
            INSERT INTO #SchemaOrg
                (DatabaseName, UserSchemaCount, UserSchemasWithObjects, TotalObjects,
                 ObjectsInDbo, ObjectsInUserSchemas, SchemaList, IsPlaceholder)
            VALUES (@db, NULL, NULL, NULL, NULL, NULL, NULL, 1);
        END CATCH

        FETCH NEXT FROM db_cur INTO @db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

IF OBJECT_ID('tempdb..#Scored') IS NOT NULL
    DROP TABLE #Scored;

CREATE TABLE #Scored
(
    DatabaseName SYSNAME        NOT NULL,
    ScoreValue   INT            NOT NULL,
    Detail       NVARCHAR(1200) NOT NULL
);

INSERT INTO #Scored (DatabaseName, ScoreValue, Detail)
SELECT
    x.DatabaseName,
    x.ScoreValue,
    x.DatabaseName + ': ' +
    CASE
        WHEN x.IsPlaceholder = 1
            THEN 'not assessable (database inaccessible to the audit login)'
        WHEN x.TotalObjects = 0
            THEN 'no user objects to organize'
        ELSE CAST(x.UserSchemasWithObjects AS VARCHAR(10)) + ' non-dbo schema(s) hold objects, '
             + CAST(x.PctOutsideDbo AS VARCHAR(10)) + '% of ' + CAST(x.TotalObjects AS VARCHAR(10))
             + ' user objects outside dbo (' + CAST(x.ObjectsInDbo AS VARCHAR(10))
             + ' in dbo); ' + CAST(x.UserSchemaCount AS VARCHAR(10)) + ' user schema(s) defined'
             + ISNULL(' [' + x.SchemaList + ']', ' [none]')
    END
FROM
(
    SELECT
        m.DatabaseName,
        m.IsPlaceholder,
        m.UserSchemaCount,
        m.UserSchemasWithObjects,
        m.TotalObjects,
        m.ObjectsInDbo,
        m.PctOutsideDbo,
        m.SchemaList,
        CASE
            WHEN m.IsPlaceholder = 1 THEN 1
            WHEN m.TotalObjects = 0 THEN 3
            WHEN m.UserSchemasWithObjects >= 2 AND m.PctOutsideDbo >= 70.0 THEN 3
            WHEN m.UserSchemasWithObjects >= 1 AND m.PctOutsideDbo >= 20.0 THEN 2
            ELSE 1
        END AS ScoreValue
    FROM
    (
        SELECT
            so.DatabaseName,
            so.IsPlaceholder,
            so.SchemaList,
            ISNULL(so.UserSchemaCount, 0)        AS UserSchemaCount,
            ISNULL(so.UserSchemasWithObjects, 0) AS UserSchemasWithObjects,
            ISNULL(so.TotalObjects, 0)           AS TotalObjects,
            ISNULL(so.ObjectsInDbo, 0)           AS ObjectsInDbo,
            CAST(CASE WHEN ISNULL(so.TotalObjects, 0) = 0 THEN 0.0
                      ELSE (so.ObjectsInUserSchemas * 100.0) / so.TotalObjects
                 END AS DECIMAL(5, 1))           AS PctOutsideDbo
        FROM #SchemaOrg AS so
    ) AS m
) AS x;

DECLARE @TotalDbs   INT = 0;
DECLARE @PassDbs    INT = 0;
DECLARE @PartialDbs INT = 0;
DECLARE @FailDbs    INT = 0;

SELECT
    @TotalDbs   = COUNT(*),
    @PassDbs    = SUM(CASE WHEN sc.ScoreValue = 3 THEN 1 ELSE 0 END),
    @PartialDbs = SUM(CASE WHEN sc.ScoreValue = 2 THEN 1 ELSE 0 END),
    @FailDbs    = SUM(CASE WHEN sc.ScoreValue = 1 THEN 1 ELSE 0 END)
FROM #Scored AS sc;

SELECT @Score = MIN(sc.ScoreValue) FROM #Scored AS sc;
SET @Score = ISNULL(@Score, 1);

SET @Result = CASE WHEN @Score = 3 THEN 'Pass' ELSE 'Fail' END;

SELECT @DatabaseQueried =
    STUFF((SELECT N', ' + sc.DatabaseName
             FROM #Scored AS sc
            ORDER BY sc.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');
SET @DatabaseQueried = ISNULL(@DatabaseQueried, N'No accessible user databases');

SELECT @Finding =
    STUFF((SELECT N' | ' + sc.Detail
             FROM #Scored AS sc
            ORDER BY sc.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 3, N'');

SET @Finding =
    CASE
        WHEN ISNULL(@TotalDbs, 0) = 0
            THEN N'No accessible user databases were found on this instance, so schema organization could not be assessed.'
        ELSE CAST(@TotalDbs AS VARCHAR(10)) + N' user database(s) evaluated: '
             + CAST(ISNULL(@PassDbs, 0) AS VARCHAR(10)) + N' well organized by schema, '
             + CAST(ISNULL(@PartialDbs, 0) AS VARCHAR(10)) + N' partially organized, '
             + CAST(ISNULL(@FailDbs, 0) AS VARCHAR(10))
             + N' with objects concentrated in dbo or not assessable. Detail - '
             + ISNULL(@Finding, N'none')
    END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Scored') IS NOT NULL
    DROP TABLE #Scored;

IF OBJECT_ID('tempdb..#SchemaOrg') IS NOT NULL
    DROP TABLE #SchemaOrg;