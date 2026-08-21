/*
    Checklist Item : 1.2.5 - Schema separation used to organize layers/domains
                     (dedicated schemas, not all in dbo)
    Scope          : SERVER (iterates all accessible user databases)
    Type           : Read-only. No data or schema is modified.
*/
SET NOCOUNT ON;

DECLARE @IsAzureDb BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#SchemaSeparation') IS NOT NULL
    DROP TABLE #SchemaSeparation;

CREATE TABLE #SchemaSeparation
(
    DatabaseName    SYSNAME,
    UserSchemaCount INT,
    TotalObjects    INT,
    DboObjects      INT,
    NonDboObjects   INT
);

DECLARE @sql NVARCHAR(MAX);

IF @IsAzureDb = 1
BEGIN
    /* Azure SQL Database: cross-database queries are not permitted, evaluate the current database only. */
    INSERT INTO #SchemaSeparation (DatabaseName, UserSchemaCount, TotalObjects, DboObjects, NonDboObjects)
    SELECT DB_NAME(),
           COUNT(DISTINCT CASE WHEN s.name <> 'dbo' THEN s.schema_id END),
           COUNT(*),
           SUM(CASE WHEN s.name = 'dbo' THEN 1 ELSE 0 END),
           SUM(CASE WHEN s.name <> 'dbo' THEN 1 ELSE 0 END)
    FROM sys.objects AS o
    INNER JOIN sys.schemas AS s
        ON s.schema_id = o.schema_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF')
      AND s.name NOT IN ('sys', 'INFORMATION_SCHEMA', 'guest');
END
ELSE
BEGIN
    DECLARE @db SYSNAME;

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND d.is_read_only IN (0, 1)
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql =
            N'SELECT ' + QUOTENAME(@db, '''') + N' AS DatabaseName,
                     COUNT(DISTINCT CASE WHEN s.name <> ''dbo'' THEN s.schema_id END) AS UserSchemaCount,
                     COUNT(*) AS TotalObjects,
                     SUM(CASE WHEN s.name = ''dbo'' THEN 1 ELSE 0 END) AS DboObjects,
                     SUM(CASE WHEN s.name <> ''dbo'' THEN 1 ELSE 0 END) AS NonDboObjects
              FROM ' + QUOTENAME(@db) + N'.sys.objects AS o
              INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s
                  ON s.schema_id = o.schema_id
              WHERE o.is_ms_shipped = 0
                AND o.type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'')
                AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'', ''guest'');';

        BEGIN TRY
            INSERT INTO #SchemaSeparation (DatabaseName, UserSchemaCount, TotalObjects, DboObjects, NonDboObjects)
            EXEC sp_executesql @sql;
        END TRY
        BEGIN CATCH
            /* Database unavailable to this login - skipped, reported as not evaluated. */
        END CATCH

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

UPDATE #SchemaSeparation
SET UserSchemaCount = ISNULL(UserSchemaCount, 0),
    TotalObjects    = ISNULL(TotalObjects, 0),
    DboObjects      = ISNULL(DboObjects, 0),
    NonDboObjects   = ISNULL(NonDboObjects, 0);

DECLARE @TotalDbs        INT = 0,
        @ScoredDbs       INT = 0,
        @CompliantDbs    INT = 0,
        @PartialDbs      INT = 0,
        @NonCompliantDbs INT = 0;

SELECT @TotalDbs = COUNT(*) FROM #SchemaSeparation;

SELECT @ScoredDbs = COUNT(*) FROM #SchemaSeparation WHERE TotalObjects >= 10;

SELECT @CompliantDbs = ISNULL(SUM(CASE
                                      WHEN UserSchemaCount >= 2
                                       AND (CAST(NonDboObjects AS DECIMAL(18, 4)) * 100.0
                                            / NULLIF(CAST(TotalObjects AS DECIMAL(18, 4)), 0)) >= 50.0
                                      THEN 1 ELSE 0
                                  END), 0),
       @PartialDbs = ISNULL(SUM(CASE
                                    WHEN UserSchemaCount >= 1
                                     AND NonDboObjects > 0
                                     AND NOT (UserSchemaCount >= 2
                                              AND (CAST(NonDboObjects AS DECIMAL(18, 4)) * 100.0
                                                   / NULLIF(CAST(TotalObjects AS DECIMAL(18, 4)), 0)) >= 50.0)
                                    THEN 1 ELSE 0
                                END), 0),
       @NonCompliantDbs = ISNULL(SUM(CASE WHEN UserSchemaCount = 0 OR NonDboObjects = 0 THEN 1 ELSE 0 END), 0)
FROM #SchemaSeparation
WHERE TotalObjects >= 10;

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + DatabaseName
           FROM #SchemaSeparation
           ORDER BY DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @Detail NVARCHAR(MAX) =
    STUFF((SELECT N'; ' + DatabaseName
                  + N' (non-dbo schemas=' + CAST(UserSchemaCount AS VARCHAR(10))
                  + N', objects=' + CAST(TotalObjects AS VARCHAR(10))
                  + N', dbo=' + CAST(DboObjects AS VARCHAR(10))
                  + N', non-dbo=' + CAST(NonDboObjects AS VARCHAR(10)) + N')'
           FROM #SchemaSeparation
           ORDER BY DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SET @DbList = ISNULL(@DbList, N'None');
SET @Detail = ISNULL(@Detail, N'No user databases were accessible.');

DECLARE @Score INT, @Result NVARCHAR(30), @Finding NVARCHAR(MAX);

IF @ScoredDbs = 0
BEGIN
    SET @Score = 0;
    SET @Result = N'Manual Review';
    SET @Finding = N'No user database contained at least 10 user objects, so schema separation could not be assessed automatically. Databases inspected: '
                   + CAST(@TotalDbs AS VARCHAR(10)) + N'. Detail: ' + @Detail;
END
ELSE
BEGIN
    IF @CompliantDbs = @ScoredDbs
        SET @Score = 3;
    ELSE IF @CompliantDbs * 2 >= @ScoredDbs
        SET @Score = 2;
    ELSE IF (@CompliantDbs + @PartialDbs) > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

    SET @Finding = N'Databases assessed: ' + CAST(@ScoredDbs AS VARCHAR(10))
                   + N' of ' + CAST(@TotalDbs AS VARCHAR(10)) + N' accessible user databases. '
                   + N'Well separated (2+ dedicated schemas and 50%+ of objects outside dbo): ' + CAST(@CompliantDbs AS VARCHAR(10))
                   + N'; partially separated: ' + CAST(@PartialDbs AS VARCHAR(10))
                   + N'; all objects in dbo: ' + CAST(@NonCompliantDbs AS VARCHAR(10))
                   + N'. Detail: ' + @Detail;
END

SELECT @Result AS Result,
       @Score  AS Score,
       @DbList AS DatabaseQueried,
       @Finding AS Finding;

IF OBJECT_ID('tempdb..#SchemaSeparation') IS NOT NULL
    DROP TABLE #SchemaSeparation;