-- Checklist: Schema/object-level permissions align with least privilege
-- Scope: DATABASE
-- Scoring: 0: public has ALTER/CONTROL/REFERENCES/DELETE/UPDATE/INSERT. 1: public has SELECT/EXECUTE on >15 objects. 2: public has SELECT/EXECUTE on <=15 objects. 3: public has no explicit grants or only SELECT/EXECUTE on <=5 objects.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @PublicId INT = (SELECT principal_id FROM sys.database_principals WHERE name = ''public'');
    DECLARE @DangerousCount INT = 0;
    DECLARE @SafeCount INT = 0;
    DECLARE @DangerousObjs NVARCHAR(MAX) = '''';
    DECLARE @SafeObjs NVARCHAR(MAX) = '''';

    SELECT @DangerousCount = COUNT(*),
           @DangerousObjs = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '')
    FROM sys.database_permissions p
    JOIN sys.objects o ON p.major_id = o.object_id
    WHERE p.grantee_principal_id = @PublicId
      AND p.minor_id = 0
      AND p.permission_name IN (''ALTER'', ''CONTROL'', ''REFERENCES'', ''DELETE'', ''UPDATE'', ''INSERT'');

    SELECT @SafeCount = COUNT(*),
           @SafeObjs = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '')
    FROM sys.database_permissions p
    JOIN sys.objects o ON p.major_id = o.object_id
    WHERE p.grantee_principal_id = @PublicId
      AND p.minor_id = 0
      AND p.permission_name IN (''SELECT'', ''EXECUTE'', ''VIEW DEFINITION'');

    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    IF @DangerousCount > 0
        SET @DbScore = 0;
    ELSE IF @SafeCount > 15
        SET @DbScore = 1;
    ELSE IF @SafeCount > 5
        SET @DbScore = 2;
    ELSE
        SET @DbScore = 3;

    SET @DbFinding = CASE
        WHEN @DbScore = 0 THEN ''public has dangerous permissions ('' + ISNULL(@DangerousObjs, ''None'') + '')''
        WHEN @DbScore = 1 THEN ''public has SELECT/EXECUTE on '' + CAST(@SafeCount AS NVARCHAR) + '' objects ('' + ISNULL(@SafeObjs, ''None'') + '')''
        WHEN @DbScore = 2 THEN ''public has SELECT/EXECUTE on '' + CAST(@SafeCount AS NVARCHAR) + '' objects ('' + ISNULL(@SafeObjs, ''None'') + '')''
        ELSE ''public has minimal or no explicit grants''
    END;

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
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
            DECLARE @PublicId INT = (SELECT principal_id FROM sys.database_principals WHERE name = ''public'');
            DECLARE @DangerousCount INT = 0;
            DECLARE @SafeCount INT = 0;
            DECLARE @DangerousObjs NVARCHAR(MAX) = '''';
            DECLARE @SafeObjs NVARCHAR(MAX) = '''';

            SELECT @DangerousCount = COUNT(*),
                   @DangerousObjs = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '')
            FROM sys.database_permissions p
            JOIN sys.objects o ON p.major_id = o.object_id
            WHERE p.grantee_principal_id = @PublicId
              AND p.minor_id = 0
              AND p.permission_name IN (''ALTER'', ''CONTROL'', ''REFERENCES'', ''DELETE'', ''UPDATE'', ''INSERT'');

            SELECT @SafeCount = COUNT(*),
                   @SafeObjs = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '')
            FROM sys.database_permissions p
            JOIN sys.objects o ON p.major_id = o.object_id
            WHERE p.grantee_principal_id = @PublicId
              AND p.minor_id = 0
              AND p.permission_name IN (''SELECT'', ''EXECUTE'', ''VIEW DEFINITION'');

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @DangerousCount > 0
                SET @DbScore = 0;
            ELSE IF @SafeCount > 15
                SET @DbScore = 1;
            ELSE IF @SafeCount > 5
                SET @DbScore = 2;
            ELSE
                SET @DbScore = 3;

            SET @DbFinding = CASE
                WHEN @DbScore = 0 THEN ''public has dangerous permissions ('' + ISNULL(@DangerousObjs, ''None'') + '')''
                WHEN @DbScore = 1 THEN ''public has SELECT/EXECUTE on '' + CAST(@SafeCount AS NVARCHAR) + '' objects ('' + ISNULL(@SafeObjs, ''None'') + '')''
                WHEN @DbScore = 2 THEN ''public has SELECT/EXECUTE on '' + CAST(@SafeCount AS NVARCHAR) + '' objects ('' + ISNULL(@SafeObjs, ''None'') + '')''
                ELSE ''public has minimal or no explicit grants''
            END;

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore, @DbFinding);
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;