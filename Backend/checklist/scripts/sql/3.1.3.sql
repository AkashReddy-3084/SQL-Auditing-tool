-- Checklist: Schema-qualified object references (dbo.Table, not Table)
-- Scope: DATABASE
-- Scoring: 3 = no unqualified references; 2 = 1-5; 1 = 6-20;
--          0 = more than 20, no database evidence, or evaluation failure.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults
(
    DbName SYSNAME NOT NULL,
    DbScore INT NOT NULL,
    Finding NVARCHAR(MAX) NOT NULL
);

IF @EngineEdition = 5
BEGIN
    DECLARE @AzureRefCount INT;
    DECLARE @AzureModules NVARCHAR(MAX);

    SELECT @AzureRefCount = COUNT(*)
    FROM sys.sql_expression_dependencies AS d
    INNER JOIN sys.objects AS o
        ON o.object_id = d.referencing_id
    WHERE d.referenced_class = 1
      AND d.referenced_entity_name IS NOT NULL
      AND d.referenced_schema_name IS NULL
      AND o.is_ms_shipped = 0
      AND o.type IN (N'P', N'FN', N'IF', N'TF', N'V', N'TR');

    SELECT @AzureModules =
        STRING_AGG(CONVERT(NVARCHAR(MAX), q.QualifiedName), N', ')
    FROM
    (
        SELECT DISTINCT QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) AS QualifiedName
        FROM sys.sql_expression_dependencies AS d
        INNER JOIN sys.objects AS o
            ON o.object_id = d.referencing_id
        INNER JOIN sys.schemas AS s
            ON s.schema_id = o.schema_id
        WHERE d.referenced_class = 1
          AND d.referenced_entity_name IS NOT NULL
          AND d.referenced_schema_name IS NULL
          AND o.is_ms_shipped = 0
          AND o.type IN (N'P', N'FN', N'IF', N'TF', N'V', N'TR')
    ) AS q;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES
    (
        DB_NAME(),
        CASE
            WHEN @AzureRefCount = 0 THEN 3
            WHEN @AzureRefCount <= 5 THEN 2
            WHEN @AzureRefCount <= 20 THEN 1
            ELSE 0
        END,
        CASE
            WHEN @AzureRefCount = 0
                THEN N'No unqualified object dependencies found in persisted SQL modules'
            ELSE CONVERT(NVARCHAR(20), @AzureRefCount)
                + N' unqualified object dependency reference(s) in module(s): '
                + COALESCE(@AzureModules, N'names unavailable')
        END
    );
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
DECLARE @RefCount INT;
DECLARE @Modules NVARCHAR(MAX);

SELECT @RefCount = COUNT(*)
FROM sys.sql_expression_dependencies AS d
INNER JOIN sys.objects AS o
    ON o.object_id = d.referencing_id
WHERE d.referenced_class = 1
  AND d.referenced_entity_name IS NOT NULL
  AND d.referenced_schema_name IS NULL
  AND o.is_ms_shipped = 0
  AND o.type IN (N''P'', N''FN'', N''IF'', N''TF'', N''V'', N''TR'');

SELECT @Modules =
    STRING_AGG(CONVERT(NVARCHAR(MAX), q.QualifiedName), N'', '')
FROM
(
    SELECT DISTINCT QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name) AS QualifiedName
    FROM sys.sql_expression_dependencies AS d
    INNER JOIN sys.objects AS o
        ON o.object_id = d.referencing_id
    INNER JOIN sys.schemas AS s
        ON s.schema_id = o.schema_id
    WHERE d.referenced_class = 1
      AND d.referenced_entity_name IS NOT NULL
      AND d.referenced_schema_name IS NULL
      AND o.is_ms_shipped = 0
      AND o.type IN (N''P'', N''FN'', N''IF'', N''TF'', N''V'', N''TR'')
) AS q;

INSERT INTO #DbResults (DbName, DbScore, Finding)
VALUES
(
    DB_NAME(),
    CASE
        WHEN @RefCount = 0 THEN 3
        WHEN @RefCount <= 5 THEN 2
        WHEN @RefCount <= 20 THEN 1
        ELSE 0
    END,
    CASE
        WHEN @RefCount = 0
            THEN N''No unqualified object dependencies found in persisted SQL modules''
        ELSE CONVERT(NVARCHAR(20), @RefCount)
            + N'' unqualified object dependency reference(s) in module(s): ''
            + COALESCE(@Modules, N''names unavailable'')
    END
);';

            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES
            (
                @DbName,
                0,
                N'Database evaluation failed: ' + ERROR_MESSAGE()
            );
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END;

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END;

SELECT @DatabaseQueried =
    STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), N', ')
FROM #DbResults;

SELECT @Score = COALESCE(MIN(DbScore), 0)
FROM #DbResults;

SELECT @Finding =
    STRING_AGG(
        CONVERT(NVARCHAR(MAX), QUOTENAME(DbName) + N': ' + Finding),
        N'; '
    )
FROM #DbResults;

SET @DatabaseQueried = COALESCE(@DatabaseQueried, N'');
SET @Finding = COALESCE(
    @Finding,
    N'No online user databases were available for evaluation'
);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;