SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#DeprecatedFindings') IS NOT NULL DROP TABLE #DeprecatedFindings;
CREATE TABLE #DeprecatedFindings (
    DatabaseName sysname NOT NULL,
    FindingCategory nvarchar(100) NOT NULL,
    ObjectName nvarchar(512) NULL,
    Detail nvarchar(1000) NULL
);

IF OBJECT_ID('tempdb..#TargetDatabases') IS NOT NULL DROP TABLE #TargetDatabases;
CREATE TABLE #TargetDatabases (
    DatabaseName sysname NOT NULL
);

INSERT INTO #TargetDatabases (DatabaseName)
SELECT d.name
FROM sys.databases d
WHERE d.database_id > 4
  AND d.state_desc = N'ONLINE'
  AND d.user_access_desc = N'MULTI_USER'
  AND HAS_DBACCESS(d.name) = 1;

DECLARE @Score int;
DECLARE @Result nvarchar(20);
DECLARE @DatabaseQueried nvarchar(20);
DECLARE @Finding nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM #TargetDatabases)
BEGIN
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SELECT
        @Result AS Result,
        @Score AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding AS Finding;
    DROP TABLE #DeprecatedFindings;
    DROP TABLE #TargetDatabases;
    RETURN;
END;

DECLARE @DbName sysname;
DECLARE @Sql nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT DatabaseName FROM #TargetDatabases ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'
USE ' + QUOTENAME(@DbName) + N';

INSERT INTO #DeprecatedFindings (DatabaseName, FindingCategory, ObjectName, Detail)
SELECT
    DB_NAME(),
    N''DeprecatedDataType'',
    QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name) + N''.'' + QUOTENAME(c.name),
    ty.name + N'' column type (deprecated)''
FROM sys.columns c
INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
INNER JOIN sys.tables t ON c.object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE ty.name IN (N''text'', N''ntext'', N''image'')
  AND t.is_ms_shipped = 0;

INSERT INTO #DeprecatedFindings (DatabaseName, FindingCategory, ObjectName, Detail)
SELECT
    DB_NAME(),
    N''DeprecatedDataType_Parameter'',
    QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name) + N'' @'' + p.name,
    ty.name + N'' parameter type (deprecated)''
FROM sys.parameters p
INNER JOIN sys.types ty ON p.user_type_id = ty.user_type_id
INNER JOIN sys.objects o ON p.object_id = o.object_id
INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
WHERE ty.name IN (N''text'', N''ntext'', N''image'')
  AND o.is_ms_shipped = 0
  AND o.type IN (N''P'', N''FN'', N''IF'', N''TF'', N''PC'', N''FS'', N''FT'');

INSERT INTO #DeprecatedFindings (DatabaseName, FindingCategory, ObjectName, Detail)
SELECT
    DB_NAME(),
    CASE
        WHEN m.definition LIKE N''%*=%'' OR m.definition LIKE N''%=*%''
            THEN N''OldStyleOuterJoin''
        WHEN m.definition LIKE N''%@@IDENTITY%''
            THEN N''DeprecatedConstruct_@@IDENTITY''
        WHEN m.definition LIKE N''%SET ROWCOUNT%''
            THEN N''DeprecatedConstruct_SET_ROWCOUNT''
        WHEN m.definition LIKE N''%sysprocesses%''
            OR m.definition LIKE N''%syslockinfo%''
            OR m.definition LIKE N''%sys.sysdatabases%''
            OR m.definition LIKE N''%sys.sysobjects%''
            OR m.definition LIKE N''%sys.sysusers%''
            THEN N''DeprecatedSystemTable''
        WHEN m.definition LIKE N''%WITH LOG%''
            OR m.definition LIKE N''%TRUNCATE ONLY%''
            THEN N''DeprecatedDBCCOrBackupSyntax''
        ELSE N''OtherDeprecatedPattern''
    END,
    QUOTENAME(OBJECT_SCHEMA_NAME(m.object_id)) + N''.'' + QUOTENAME(OBJECT_NAME(m.object_id)),
    CASE
        WHEN m.definition LIKE N''%*=%'' OR m.definition LIKE N''%=*%''
            THEN N''Old-style outer join operator (*= or =*) detected in module definition''
        WHEN m.definition LIKE N''%@@IDENTITY%''
            THEN N''@@IDENTITY usage detected; prefer SCOPE_IDENTITY() or OUTPUT''
        WHEN m.definition LIKE N''%SET ROWCOUNT%''
            THEN N''SET ROWCOUNT detected; prefer TOP''
        WHEN m.definition LIKE N''%sysprocesses%''
            OR m.definition LIKE N''%syslockinfo%''
            OR m.definition LIKE N''%sys.sysdatabases%''
            OR m.definition LIKE N''%sys.sysobjects%''
            OR m.definition LIKE N''%sys.sysusers%''
            THEN N''Reference to deprecated system table/view compatibility object''
        WHEN m.definition LIKE N''%WITH LOG%''
            OR m.definition LIKE N''%TRUNCATE ONLY%''
            THEN N''Deprecated DBCC/backup option syntax detected''
        ELSE N''Deprecated pattern matched''
    END
FROM sys.sql_modules m
INNER JOIN sys.objects o ON m.object_id = o.object_id
WHERE o.is_ms_shipped = 0
  AND m.definition IS NOT NULL
  AND (
        m.definition LIKE N''%*=%''
     OR m.definition LIKE N''%=*%''
     OR m.definition LIKE N''%@@IDENTITY%''
     OR m.definition LIKE N''%SET ROWCOUNT%''
     OR m.definition LIKE N''%sysprocesses%''
     OR m.definition LIKE N''%syslockinfo%''
     OR m.definition LIKE N''%sys.sysdatabases%''
     OR m.definition LIKE N''%sys.sysobjects%''
     OR m.definition LIKE N''%sys.sysusers%''
     OR m.definition LIKE N''%WITH LOG%''
     OR m.definition LIKE N''%TRUNCATE ONLY%''
  );
';

    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        -- Skip databases that cannot be queried; continue with remaining targets.
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @DbCount int = (SELECT COUNT(*) FROM #TargetDatabases);
DECLARE @Total int = (SELECT COUNT(*) FROM #DeprecatedFindings);
DECLARE @DeprecatedTypes int = (
    SELECT COUNT(*) FROM #DeprecatedFindings
    WHERE FindingCategory IN (N'DeprecatedDataType', N'DeprecatedDataType_Parameter')
);
DECLARE @OldOuter int = (
    SELECT COUNT(*) FROM #DeprecatedFindings
    WHERE FindingCategory = N'OldStyleOuterJoin'
);
DECLARE @Other int = (
    SELECT COUNT(*) FROM #DeprecatedFindings
    WHERE FindingCategory NOT IN (N'DeprecatedDataType', N'DeprecatedDataType_Parameter', N'OldStyleOuterJoin')
);

DECLARE @Sample nvarchar(max) = N'';
SELECT TOP 8 @Sample = @Sample +
    CASE WHEN @Sample = N'' THEN N'' ELSE N'; ' END +
    DatabaseName + N': ' + FindingCategory + N' on ' + ISNULL(ObjectName, N'(n/a)')
FROM #DeprecatedFindings
ORDER BY
    CASE FindingCategory
        WHEN N'DeprecatedDataType' THEN 1
        WHEN N'DeprecatedDataType_Parameter' THEN 2
        WHEN N'OldStyleOuterJoin' THEN 3
        ELSE 4
    END,
    DatabaseName,
    ObjectName;

SET @DatabaseQueried = N'ALL';

IF @Total = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No deprecated data types (TEXT/NTEXT/IMAGE) and no common deprecated syntax patterns detected across ' + CAST(@DbCount AS nvarchar(20)) + N' user database(s).';
END
ELSE IF @DeprecatedTypes > 0 OR @OldOuter > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Found ' + CAST(@Total AS nvarchar(20)) + N' deprecated feature finding(s) in user databases (' +
        CAST(@DeprecatedTypes AS nvarchar(20)) + N' TEXT/NTEXT/IMAGE type usage(s); ' +
        CAST(@OldOuter AS nvarchar(20)) + N' old-style outer join(s); ' +
        CAST(@Other AS nvarchar(20)) + N' other deprecated construct(s)). Samples: ' + @Sample;
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = N'Found ' + CAST(@Total AS nvarchar(20)) + N' lower-severity deprecated construct finding(s) (no TEXT/NTEXT/IMAGE or old-style outer joins). Samples: ' + @Sample;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;

DROP TABLE #DeprecatedFindings;
DROP TABLE #TargetDatabases;