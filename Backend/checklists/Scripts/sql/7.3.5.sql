SET NOCOUNT ON;

/* Read-only audit: 7.3.5 - Consent / purpose tracking integrated where applicable */

DECLARE @Result           NVARCHAR(20);
DECLARE @Score            INT;
DECLARE @DatabaseQueried  NVARCHAR(MAX);
DECLARE @Finding          NVARCHAR(MAX);

DECLARE @IsAzure BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

DECLARE @Scanned TABLE (DatabaseName SYSNAME PRIMARY KEY);
DECLARE @Skipped TABLE (DatabaseName SYSNAME PRIMARY KEY);
DECLARE @Artifacts TABLE
(
    DatabaseName SYSNAME,
    Category     NVARCHAR(20),
    ObjectDesc   NVARCHAR(600)
);

DECLARE @db SYSNAME;
DECLARE @sql NVARCHAR(MAX);

IF @IsAzure = 1
BEGIN
    INSERT INTO @Scanned (DatabaseName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO @Scanned (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0                  /* ONLINE */
      AND d.is_in_standby = 0
      AND d.source_database_id IS NULL /* exclude snapshots */
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM @Scanned ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
    WITH objs AS
    (
        SELECT N''TABLE'' AS k, s.name AS sch, t.name AS nm, CAST(NULL AS SYSNAME) AS col
        FROM ' + QUOTENAME(@db) + N'.sys.tables AS t
        JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
        UNION ALL
        SELECT N''VIEW'', s.name, v.name, NULL
        FROM ' + QUOTENAME(@db) + N'.sys.views AS v
        JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = v.schema_id
        WHERE v.is_ms_shipped = 0
        UNION ALL
        SELECT N''COLUMN'', s.name, t.name, c.name
        FROM ' + QUOTENAME(@db) + N'.sys.columns AS c
        JOIN ' + QUOTENAME(@db) + N'.sys.tables AS t ON t.object_id = c.object_id
        JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
    )
    SELECT TOP (2000)
           @p_db AS DatabaseName,
           cat.Category,
           LEFT(o.k + N'': '' + QUOTENAME(o.sch) + N''.'' + QUOTENAME(o.nm)
                + ISNULL(N''.'' + QUOTENAME(o.col), N''''), 600) AS ObjectDesc
    FROM objs AS o
    CROSS APPLY (SELECT LOWER(ISNULL(o.col, o.nm)) AS n) AS t
    CROSS APPLY (VALUES (
        CASE
            WHEN t.n LIKE N''%consent%''
              OR t.n LIKE N''%opt[_]in%''  OR t.n LIKE N''%optin%''
              OR t.n LIKE N''%opt[_]out%'' OR t.n LIKE N''%optout%''
              OR t.n LIKE N''%permission[_]preference%''
              OR t.n LIKE N''%privacy[_]preference%''
              OR t.n LIKE N''%marketing[_]preference%''
                 THEN N''CONSENT''
            WHEN t.n LIKE N''%purpose%''
              OR t.n LIKE N''%lawful[_]basis%''  OR t.n LIKE N''%lawfulbasis%''
              OR t.n LIKE N''%legal[_]basis%''   OR t.n LIKE N''%legalbasis%''
              OR t.n LIKE N''%processing[_]reason%''
              OR t.n LIKE N''%data[_]use%''
                 THEN N''PURPOSE''
            WHEN o.col IS NOT NULL
             AND ( t.n LIKE N''%email%''
                OR t.n LIKE N''%phone%''        OR t.n LIKE N''%mobile[_]no%''
                OR t.n LIKE N''%ssn%''          OR t.n LIKE N''%national[_]id%''
                OR t.n LIKE N''%passport%''     OR t.n LIKE N''%date[_]of[_]birth%''
                OR t.n LIKE N''%dob%''          OR t.n LIKE N''%birth[_]date%''
                OR t.n LIKE N''%first[_]name%'' OR t.n LIKE N''%last[_]name%''
                OR t.n LIKE N''%home[_]address%'' )
                 THEN N''PII''
            ELSE NULL
        END)) AS cat(Category)
    WHERE cat.Category IS NOT NULL
    ORDER BY cat.Category, ObjectDesc;';

    BEGIN TRY
        INSERT INTO @Artifacts (DatabaseName, Category, ObjectDesc)
        EXEC sp_executesql @sql, N'@p_db SYSNAME', @p_db = @db;
    END TRY
    BEGIN CATCH
        INSERT INTO @Skipped (DatabaseName)
        SELECT @db WHERE NOT EXISTS (SELECT 1 FROM @Skipped WHERE DatabaseName = @db);
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @ConsentCount INT = (SELECT COUNT(*) FROM @Artifacts WHERE Category = N'CONSENT');
DECLARE @PurposeCount INT = (SELECT COUNT(*) FROM @Artifacts WHERE Category = N'PURPOSE');
DECLARE @PiiCount     INT = (SELECT COUNT(*) FROM @Artifacts WHERE Category = N'PII');
DECLARE @DbCount      INT = (SELECT COUNT(*) FROM @Scanned);
DECLARE @SkipCount    INT = (SELECT COUNT(*) FROM @Skipped);

SET @DatabaseQueried =
    ISNULL(STUFF((SELECT N', ' + s.DatabaseName
                  FROM @Scanned AS s
                  ORDER BY s.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'NONE');

DECLARE @ConsentSample NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N'; ' + x.DatabaseName + N' -> ' + x.ObjectDesc
                  FROM (SELECT TOP (5) a.DatabaseName, a.ObjectDesc
                        FROM @Artifacts AS a
                        WHERE a.Category = N'CONSENT'
                        ORDER BY a.DatabaseName, a.ObjectDesc) AS x
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @PurposeSample NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N'; ' + x.DatabaseName + N' -> ' + x.ObjectDesc
                  FROM (SELECT TOP (5) a.DatabaseName, a.ObjectDesc
                        FROM @Artifacts AS a
                        WHERE a.Category = N'PURPOSE'
                        ORDER BY a.DatabaseName, a.ObjectDesc) AS x
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @PiiSample NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N'; ' + x.DatabaseName + N' -> ' + x.ObjectDesc
                  FROM (SELECT TOP (5) a.DatabaseName, a.ObjectDesc
                        FROM @Artifacts AS a
                        WHERE a.Category = N'PII'
                        ORDER BY a.DatabaseName, a.ObjectDesc) AS x
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @SkipList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N', ' + s.DatabaseName
                  FROM @Skipped AS s
                  ORDER BY s.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

SET @Score =
    CASE
        WHEN @ConsentCount > 0 AND @PurposeCount > 0 THEN 3
        WHEN @ConsentCount > 0 OR  @PurposeCount > 0 THEN 2
        WHEN @PiiCount > 0                           THEN 0
        ELSE 1
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
    N'Scanned ' + CAST(@DbCount AS NVARCHAR(10)) + N' user database(s)'
    + CASE WHEN @SkipCount > 0
           THEN N' (' + CAST(@SkipCount AS NVARCHAR(10)) + N' inaccessible and skipped: ' + @SkipList + N')'
           ELSE N'' END
    + N'. Consent artifacts: ' + CAST(@ConsentCount AS NVARCHAR(10))
    + N'; purpose/lawful-basis artifacts: ' + CAST(@PurposeCount AS NVARCHAR(10))
    + N'; personal-data indicator columns: ' + CAST(@PiiCount AS NVARCHAR(10)) + N'. '
    + CASE
        WHEN @ConsentCount > 0 AND @PurposeCount > 0
            THEN N'Consent tracking is integrated together with the purpose/lawful basis of processing. Consent examples: '
                 + @ConsentSample + N'. Purpose examples: ' + @PurposeSample + N'.'
        WHEN @ConsentCount > 0 AND @PurposeCount = 0
            THEN N'Consent artifacts exist but no purpose/lawful-basis attribute was found, so consent is not tied to a processing purpose. Consent examples: '
                 + @ConsentSample + N'.'
        WHEN @ConsentCount = 0 AND @PurposeCount > 0
            THEN N'Purpose/lawful-basis metadata exists but no consent capture artifact was found. Purpose examples: '
                 + @PurposeSample + N'.'
        WHEN @PiiCount > 0
            THEN N'No consent or purpose tracking artifacts were found although personal-data columns are present. Personal-data examples: '
                 + @PiiSample + N'.'
        ELSE N'No consent, purpose or personal-data indicators were found in the scanned metadata; there is no evidence of consent/purpose tracking and applicability should be confirmed manually.'
      END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;