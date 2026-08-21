SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;

CREATE TABLE #Findings
(
    DatabaseName sysname        NOT NULL,
    ObjectName   nvarchar(600)  NOT NULL,
    IssueType    nvarchar(100)  NOT NULL,
    Detail       nvarchar(400)  NULL
);

CREATE TABLE #Dbs
(
    DatabaseName sysname NOT NULL,
    Scanned      bit     NOT NULL
);

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @DbName sysname;
DECLARE @Sql    nvarchar(max);

DECLARE @Template nvarchar(max) = N'
INSERT INTO #Findings (DatabaseName, ObjectName, IssueType, Detail)
SELECT @db,
       QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name) + N''.'' + QUOTENAME(c.name),
       N''Deprecated column data type'',
       t.name
FROM {P}sys.columns AS c
INNER JOIN {P}sys.objects AS o ON o.object_id = c.object_id
INNER JOIN {P}sys.schemas AS s ON s.schema_id = o.schema_id
INNER JOIN {P}sys.types   AS t ON t.user_type_id = c.system_type_id
                              AND t.is_user_defined = 0
WHERE o.is_ms_shipped = 0
  AND o.type IN (N''U'', N''V'')
  AND t.name IN (N''text'', N''ntext'', N''image'', N''timestamp'');

INSERT INTO #Findings (DatabaseName, ObjectName, IssueType, Detail)
SELECT @db,
       QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name) + N'' (parameter '' + p.name + N'')'',
       N''Deprecated parameter data type'',
       t.name
FROM {P}sys.parameters AS p
INNER JOIN {P}sys.objects AS o ON o.object_id = p.object_id
INNER JOIN {P}sys.schemas AS s ON s.schema_id = o.schema_id
INNER JOIN {P}sys.types   AS t ON t.user_type_id = p.system_type_id
                              AND t.is_user_defined = 0
WHERE o.is_ms_shipped = 0
  AND t.name IN (N''text'', N''ntext'', N''image'');

INSERT INTO #Findings (DatabaseName, ObjectName, IssueType, Detail)
SELECT @db,
       QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name),
       N''Old-style outer join operator'',
       CASE WHEN m.definition LIKE N''%*=%'' AND m.definition LIKE N''%=*%'' THEN N''*= and =*''
            WHEN m.definition LIKE N''%*=%'' THEN N''*=''
            ELSE N''=*''
       END
FROM {P}sys.sql_modules AS m
INNER JOIN {P}sys.objects AS o ON o.object_id = m.object_id
INNER JOIN {P}sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND m.definition IS NOT NULL
  AND (m.definition LIKE N''%*=%'' OR m.definition LIKE N''%=*%'');

INSERT INTO #Findings (DatabaseName, ObjectName, IssueType, Detail)
SELECT @db,
       QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name),
       N''Deprecated construct'',
       pat.Label
FROM {P}sys.sql_modules AS m
INNER JOIN {P}sys.objects AS o ON o.object_id = m.object_id
INNER JOIN {P}sys.schemas AS s ON s.schema_id = o.schema_id
CROSS APPLY (VALUES
        (N''%SET ROWCOUNT%'', N''SET ROWCOUNT''),
        (N''%FASTFIRSTROW%'', N''FASTFIRSTROW hint''),
        (N''%sp_dboption%'',  N''sp_dboption''),
        (N''%sp_attach_db%'', N''sp_attach_db''),
        (N''%sp_addtype%'',   N''sp_addtype''),
        (N''%READTEXT%'',     N''READTEXT''),
        (N''%WRITETEXT%'',    N''WRITETEXT''),
        (N''%UPDATETEXT%'',   N''UPDATETEXT''),
        (N''%TEXTPTR%'',      N''TEXTPTR''),
        (N''%sysobjects%'',   N''sysobjects compatibility view''),
        (N''%syscolumns%'',   N''syscolumns compatibility view''),
        (N''%sysindexes%'',   N''sysindexes compatibility view''),
        (N''%sysusers%'',     N''sysusers compatibility view'')
    ) AS pat(Pattern, Label)
WHERE o.is_ms_shipped = 0
  AND m.definition IS NOT NULL
  AND m.definition COLLATE Latin1_General_CI_AS LIKE pat.Pattern;

INSERT INTO #Findings (DatabaseName, ObjectName, IssueType, Detail)
SELECT @db,
       QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name),
       N''Encrypted module - manual review'',
       NULL
FROM {P}sys.sql_modules AS m
INNER JOIN {P}sys.objects AS o ON o.object_id = m.object_id
INNER JOIN {P}sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND m.definition IS NULL;
';

IF @EngineEdition IN (5, 6, 9, 11)
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = REPLACE(@Template, N'{P}', N'');

    BEGIN TRY
        EXEC sp_executesql @Sql, N'@db sysname', @db = @DbName;
        INSERT INTO #Dbs (DatabaseName, Scanned) VALUES (@DbName, 1);
    END TRY
    BEGIN CATCH
        INSERT INTO #Dbs (DatabaseName, Scanned) VALUES (@DbName, 0);
    END CATCH
END
ELSE
BEGIN
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = REPLACE(@Template, N'{P}', QUOTENAME(@DbName) + N'.');

        BEGIN TRY
            EXEC sp_executesql @Sql, N'@db sysname', @db = @DbName;
            INSERT INTO #Dbs (DatabaseName, Scanned) VALUES (@DbName, 1);
        END TRY
        BEGIN CATCH
            INSERT INTO #Dbs (DatabaseName, Scanned) VALUES (@DbName, 0);
        END CATCH

        FETCH NEXT FROM db_cur INTO @DbName;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @Scanned      int = (SELECT COUNT(*) FROM #Dbs WHERE Scanned = 1);
DECLARE @Skipped      int = (SELECT COUNT(*) FROM #Dbs WHERE Scanned = 0);
DECLARE @Encrypted    int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = N'Encrypted module - manual review');
DECLARE @Total        int = (SELECT COUNT(*) FROM #Findings WHERE IssueType <> N'Encrypted module - manual review');
DECLARE @AffectedDbs  int = (SELECT COUNT(DISTINCT DatabaseName) FROM #Findings WHERE IssueType <> N'Encrypted module - manual review');

DECLARE @DbList nvarchar(max) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #Dbs AS d
           WHERE d.Scanned = 1
           ORDER BY d.DatabaseName
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

DECLARE @Sample nvarchar(max);

;WITH Ranked AS
(
    SELECT TOP (5) f.DatabaseName, f.ObjectName, f.IssueType, f.Detail
    FROM #Findings AS f
    WHERE f.IssueType <> N'Encrypted module - manual review'
    ORDER BY f.DatabaseName, f.IssueType, f.ObjectName
)
SELECT @Sample =
    STUFF((SELECT N'; ' + r.DatabaseName + N'.' + r.ObjectName
                  + N' (' + r.IssueType + N': ' + ISNULL(r.Detail, N'n/a') + N')'
           FROM Ranked AS r
           ORDER BY r.DatabaseName, r.IssueType, r.ObjectName
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

DECLARE @Result  nvarchar(20);
DECLARE @Score   int;
DECLARE @Finding nvarchar(max);

DECLARE @CheckedText nvarchar(600) =
    N'Checked: text/ntext/image/timestamp columns, text/ntext/image parameters, old-style outer joins (*=, =*), and deprecated constructs (SET ROWCOUNT, FASTFIRSTROW, sp_dboption, sp_attach_db, sp_addtype, READTEXT/WRITETEXT/UPDATETEXT/TEXTPTR, sysobjects/syscolumns/sysindexes/sysusers).';

IF @Scanned = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No user database could be scanned for deprecated syntax or data types (user databases inaccessible, or none exist). Databases skipped due to access errors: '
                   + CAST(@Skipped AS nvarchar(10)) + N'. Compliance could not be evidenced; manual review required.';
END
ELSE IF @Total = 0 AND @Encrypted > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'No deprecated syntax or data types were detected in ' + CAST(@Scanned AS nvarchar(10))
                   + N' scanned user database(s), but ' + CAST(@Encrypted AS nvarchar(10))
                   + N' encrypted module(s) could not be inspected, so coverage is incomplete. ' + @CheckedText;
END
ELSE IF @Total = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No deprecated syntax or data types detected across ' + CAST(@Scanned AS nvarchar(10))
                   + N' scanned user database(s). ' + @CheckedText;
END
ELSE IF @Total <= 10
BEGIN
    SET @Score = 2;
    SET @Finding = N'Found ' + CAST(@Total AS nvarchar(10)) + N' deprecated usage(s) in ' + CAST(@AffectedDbs AS nvarchar(10))
                   + N' of ' + CAST(@Scanned AS nvarchar(10)) + N' scanned user database(s). Examples: ' + ISNULL(@Sample, N'n/a')
                   + N'. Encrypted modules not inspectable: ' + CAST(@Encrypted AS nvarchar(10))
                   + N'. Note: *= / =* matches can also be the compound assignment operator and need manual confirmation.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'Found ' + CAST(@Total AS nvarchar(10)) + N' deprecated usage(s) in ' + CAST(@AffectedDbs AS nvarchar(10))
                   + N' of ' + CAST(@Scanned AS nvarchar(10)) + N' scanned user database(s). Examples: ' + ISNULL(@Sample, N'n/a')
                   + N'. Encrypted modules not inspectable: ' + CAST(@Encrypted AS nvarchar(10))
                   + N'. Note: *= / =* matches can also be the compound assignment operator and need manual confirmation.';
END

IF @Skipped > 0 AND @Scanned > 0
    SET @Finding = @Finding + N' ' + CAST(@Skipped AS nvarchar(10)) + N' database(s) were skipped due to access errors.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result                        AS Result,
    @Score                         AS Score,
    ISNULL(@DbList, N'None')       AS DatabaseQueried,
    @Finding                       AS Finding;

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;