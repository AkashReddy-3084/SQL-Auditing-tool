-- Checklist: Indexes/constraints managed during large loads (disable/rebuild where beneficial)
-- Scope: DATABASE
-- Scoring: 0: No management patterns in modules and no disabled indexes/untrusted constraints. 1: Indirect evidence only (disabled indexes/untrusted constraints exist). 2: 1-2 modules contain management patterns. 3: >=3 modules contain management patterns.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    
    BEGIN TRY
        DECLARE @PatternCount INT = 0;
        DECLARE @DisabledIndexCount INT = 0;
        DECLARE @UntrustedConstraintCount INT = 0;
        DECLARE @PatternObjects NVARCHAR(MAX) = '';
        DECLARE @DisabledObjects NVARCHAR(MAX) = '';

        SELECT @PatternCount = COUNT(DISTINCT object_id),
               @PatternObjects = STRING_AGG(OBJECT_NAME(object_id), ', ')
        FROM sys.sql_modules
        WHERE definition LIKE '%DISABLE%'
           OR definition LIKE '%REBUILD%'
           OR definition LIKE '%NOCHECK%'
           OR definition LIKE '%CHECK CONSTRAINT%';

        SELECT @DisabledIndexCount = COUNT(*)
        FROM sys.indexes
        WHERE is_disabled = 1;

        SELECT @UntrustedConstraintCount = COUNT(*)
        FROM (
            SELECT name FROM sys.check_constraints WHERE is_not_trusted = 1
            UNION ALL
            SELECT name FROM sys.foreign_keys WHERE is_not_trusted = 1
        ) AS u;

        SELECT @DisabledObjects = STRING_AGG(OBJECT_NAME(parent_object_id) + '.' + name, ', ')
        FROM (
            SELECT parent_object_id, name FROM sys.check_constraints WHERE is_not_trusted = 1
            UNION ALL
            SELECT parent_object_id, name FROM sys.foreign_keys WHERE is_not_trusted = 1
        ) AS u;

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (
            @DbName,
            CASE 
                WHEN @PatternCount >= 3 THEN 3
                WHEN @PatternCount >= 1 THEN 2
                WHEN @DisabledIndexCount > 0 OR @UntrustedConstraintCount > 0 THEN 1
                ELSE 0
            END,
            CASE 
                WHEN @PatternCount >= 3 THEN 'Found ' + CAST(@PatternCount AS NVARCHAR) + ' modules with index/constraint management patterns: ' + @PatternObjects
                WHEN @PatternCount >= 1 THEN 'Found ' + CAST(@PatternCount AS NVARCHAR) + ' modules with index/constraint management patterns: ' + @PatternObjects
                WHEN @DisabledIndexCount > 0 OR @UntrustedConstraintCount > 0 THEN 'Indirect evidence: ' + CAST(@DisabledIndexCount AS NVARCHAR) + ' disabled indexes, ' + CAST(@UntrustedConstraintCount AS NVARCHAR) + ' untrusted constraints. Objects: ' + @DisabledObjects
                ELSE 'No evidence of index/constraint management during loads found.'
            END
        );
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
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
            DECLARE @PatternCount INT = 0;
            DECLARE @DisabledIndexCount INT = 0;
            DECLARE @UntrustedConstraintCount INT = 0;
            DECLARE @PatternObjects NVARCHAR(MAX) = '''';
            DECLARE @DisabledObjects NVARCHAR(MAX) = '''';

            SELECT @PatternCount = COUNT(DISTINCT object_id),
                   @PatternObjects = STRING_AGG(OBJECT_NAME(object_id), '','' )
            FROM sys.sql_modules
            WHERE definition LIKE ''%DISABLE%''
               OR definition LIKE ''%REBUILD%''
               OR definition LIKE ''%NOCHECK%''
               OR definition LIKE ''%CHECK CONSTRAINT%'';

            SELECT @DisabledIndexCount = COUNT(*)
            FROM sys.indexes
            WHERE is_disabled = 1;

            SELECT @UntrustedConstraintCount = COUNT(*)
            FROM (
                SELECT name FROM sys.check_constraints WHERE is_not_trusted = 1
                UNION ALL
                SELECT name FROM sys.foreign_keys WHERE is_not_trusted = 1
            ) AS u;

            SELECT @DisabledObjects = STRING_AGG(OBJECT_NAME(parent_object_id) + ''.'' + name, '','' )
            FROM (
                SELECT parent_object_id, name FROM sys.check_constraints WHERE is_not_trusted = 1
                UNION ALL
                SELECT parent_object_id, name FROM sys.foreign_keys WHERE is_not_trusted = 1
            ) AS u;