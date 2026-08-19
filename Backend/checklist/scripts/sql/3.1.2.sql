-- Checklist: No SELECT * in production code; explicit column lists
-- Scope: DATABASE
-- Scoring: 3 = no SELECT * and all module definitions readable;
--          2 = no SELECT * but some definitions unreadable; 1 = 1-5 matching
--          modules; 0 = more than 5 matches, no database evidence, or failure.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    DECLARE @AzureMatchCount INT = 0;
    DECLARE @AzureUnreadableCount INT = 0;
    DECLARE @AzureMatches NVARCHAR(MAX);
    DECLARE @AzureUnreadable NVARCHAR(MAX);

    SELECT @AzureMatchCount = COUNT(*)
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o
        ON o.object_id = m.object_id
    CROSS APPLY
    (
        SELECT LOWER(
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                m.definition,
                CHAR(13), N' '),
                CHAR(10), N' '),
                CHAR(9), N' '),
                N'  ', N' '),
                N'  ', N' '),
                N'  ', N' ')
        ) AS NormalizedDefinition
    ) AS n
    WHERE o.is_ms_shipped = 0
      AND o.type IN (N'P', N'FN', N'IF', N'TF', N'V', N'TR')
      AND m.definition IS NOT NULL
      AND
      (
           n.NormalizedDefinition LIKE N'%select *%'
        OR n.NormalizedDefinition LIKE N'%select all *%'
        OR n.NormalizedDefinition LIKE N'%select distinct *%'
      );

    SELECT @AzureMatches =
        STRING_AGG(CONVERT(NVARCHAR(MAX), q.QualifiedName), N', ')
    FROM
    (
        SELECT DISTINCT QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) AS QualifiedName
        FROM sys.sql_modules AS m
        INNER JOIN sys.objects AS o
            ON o.object_id = m.object_id
        INNER JOIN sys.schemas AS s
            ON s.schema_id = o.schema_id
        CROSS APPLY
        (
            SELECT LOWER(
                REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    m.definition,
                    CHAR(13), N' '),
                    CHAR(10), N' '),
                    CHAR(9), N' '),
                    N'  ', N' '),
                    N'  ', N' '),
                    N'  ', N' ')
            ) AS NormalizedDefinition
        ) AS n
        WHERE o.is_ms_shipped = 0
          AND o.type IN (N'P', N'FN', N'IF', N'TF', N'V', N'TR')
          AND m.definition IS NOT NULL
          AND
          (
               n.NormalizedDefinition LIKE N'%select *%'
            OR n.NormalizedDefinition LIKE N'%select all *%'
            OR n.NormalizedDefinition LIKE N'%select distinct *%'
          )
    ) AS q;

    SELECT
        @AzureUnreadableCount = COUNT(*),
        @AzureUnreadable =
            STRING_AGG(
                CONVERT(NVARCHAR(MAX), QUOTENAME(s.name) + N'.' + QUOTENAME(o.name)),
                N', '
            )
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o
        ON o.object_id = m.object_id
    INNER JOIN sys.schemas AS s
        ON s.schema_id = o.schema_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN (N'P', N'FN', N'IF', N'TF', N'V', N'TR')
      AND m.definition IS NULL;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES
    (
        DB_NAME(),
        CASE
            WHEN @AzureMatchCount > 5 THEN 0
            WHEN @AzureMatchCount > 0 THEN 1
            WHEN @AzureUnreadableCount > 0 THEN 2
            ELSE 3
        END,
        CASE
            WHEN @AzureMatchCount > 0
                THEN CONVERT(NVARCHAR(20), @AzureMatchCount)
                    + N' module(s) contain SELECT * patterns: '
                    + COALESCE(@AzureMatches, N'names unavailable')
            WHEN @AzureUnreadableCount > 0
                THEN N'No SELECT * pattern found in readable modules; '
                    + CONVERT(NVARCHAR(20), @AzureUnreadableCount)
                    + N' unreadable module(s): '
                    + COALESCE(@AzureUnreadable, N'names unavailable')
            ELSE N'No SELECT * pattern found in readable persisted SQL modules'
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
DECLARE @MatchCount INT = 0;
DECLARE @UnreadableCount INT = 0;
DECLARE @Matches NVARCHAR(MAX);
DECLARE @Unreadable NVARCHAR(MAX);

SELECT @MatchCount = COUNT(*)
FROM sys.sql_modules AS m
INNER JOIN sys.objects AS o
    ON o.object_id = m.object_id
CROSS APPLY
(
    SELECT LOWER(
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            m.definition,
            CHAR(13), N'' ''),
            CHAR(10), N'' ''),
            CHAR(9), N'' ''),
            N''  '', N'' ''),
            N''  '', N'' ''),
            N''  '', N'' '')
    ) AS NormalizedDefinition
) AS n
WHERE o.is_ms_shipped = 0
  AND o.type IN (N''P'', N''FN'', N''IF'', N''TF'', N''V'', N''TR'')
  AND m.definition IS NOT NULL
  AND
  (
       n.NormalizedDefinition LIKE N''%select *%''
    OR n.NormalizedDefinition LIKE N''%select all *%''
    OR n.NormalizedDefinition LIKE N''%select distinct *%''
  );

SELECT @Matches =
    STRING_AGG(CONVERT(NVARCHAR(MAX), q.QualifiedName), N'', '')
FROM
(
    SELECT DISTINCT QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name) AS QualifiedName
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o
        ON o.object_id = m.object_id
    INNER JOIN sys.schemas AS s
        ON s.schema_id = o.schema_id
    CROSS APPLY
    (
        SELECT LOWER(
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                m.definition,
                CHAR(13), N'' ''),
                CHAR(10), N'' ''),
                CHAR(9), N'' ''),
                N''  '', N'' ''),
                N''  '', N'' ''),
                N''  '', N'' '')
        ) AS NormalizedDefinition
    ) AS n
    WHERE o.is_ms_shipped = 0
      AND o.type IN (N''P'', N''FN'', N''IF'', N''TF'', N''V'', N''TR'')
      AND m.definition IS NOT NULL
      AND
      (
           n.NormalizedDefinition LIKE N''%select *%''
        OR n.NormalizedDefinition LIKE N''%select all *%''
        OR n.NormalizedDefinition LIKE N''%select distinct *%''
      )
) AS q;

SELECT
    @UnreadableCount = COUNT(*),
    @Unreadable =
        STRING_AGG(
            CONVERT(NVARCHAR(MAX), QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name)),
            N'', ''
        )
FROM sys.sql_modules AS m
INNER JOIN sys.objects AS o
    ON o.object_id = m.object_id
INNER JOIN sys.schemas AS s
    ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN (N''P'', N''FN'', N''IF'', N''TF'', N''V'', N''TR'')
  AND m.definition IS NULL;

INSERT INTO #DbResults (DbName, DbScore, Finding)
VALUES
(
    DB_NAME(),
    CASE
        WHEN @MatchCount > 5 THEN 0
        WHEN @MatchCount > 0 THEN 1
        WHEN @UnreadableCount > 0 THEN 2
        ELSE 3
    END,
    CASE
        WHEN @MatchCount > 0
            THEN CONVERT(NVARCHAR(20), @MatchCount)
                + N'' module(s) contain SELECT * patterns: ''
                + COALESCE(@Matches, N''names unavailable'')
        WHEN @UnreadableCount > 0
            THEN N''No SELECT * pattern found in readable modules; ''
                + CONVERT(NVARCHAR(20), @UnreadableCount)
                + N'' unreadable module(s): ''
                + COALESCE(@Unreadable, N''names unavailable'')
        ELSE N''No SELECT * pattern found in readable persisted SQL modules''
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
                N'Database module evaluation failed: ' + ERROR_MESSAGE()
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
    N'No online user databases were available for module evaluation'
);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;