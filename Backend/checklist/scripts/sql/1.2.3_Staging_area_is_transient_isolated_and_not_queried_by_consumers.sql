-- Checklist: Staging area is transient/isolated and not queried by consumers
-- Scope: DATABASE
-- Scoring: 3: No staging objects or zero downstream references. 2: 1-2 downstream references. 1: 3-5 downstream references. 0: >5 downstream references.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @StagingCount INT = 0;
    DECLARE @RefCount INT = 0;
    DECLARE @RefObjects NVARCHAR(MAX) = '''';

    SELECT @StagingCount = COUNT(*)
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%tmp%'' OR s.name LIKE ''%temp%'' OR s.name LIKE ''%stage%''
       OR t.name LIKE ''%stg%'' OR t.name LIKE ''%landing%'' OR t.name LIKE ''%raw%'' OR t.name LIKE ''%tmp%'' OR t.name LIKE ''%temp%'' OR t.name LIKE ''%stage%'';

    IF @StagingCount > 0
    BEGIN
        SELECT @RefCount = COUNT(DISTINCT referencing_id),
               @RefObjects = STRING_AGG(QUOTENAME(OBJECT_SCHEMA_NAME(referencing_id)) + ''.'' + QUOTENAME(OBJECT_NAME(referencing_id)), '', '')
        FROM sys.sql_expression_dependencies sed
        JOIN sys.objects ref_obj ON sed.referencing_id = ref_obj.object_id
        JOIN sys.schemas ref_s ON ref_obj.schema_id = ref_s.schema_id
        WHERE sed.class = 1
          AND sed.referencing_id IS NOT NULL
          AND sed.referenced_id IN (
              SELECT t.object_id FROM sys.tables t
              JOIN sys.schemas s ON t.schema_id = s.schema_id
              WHERE s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%tmp%'' OR s.name LIKE ''%temp%'' OR s.name LIKE ''%stage%''
                 OR t.name LIKE ''%stg%'' OR t.name LIKE ''%landing%'' OR t.name LIKE ''%raw%'' OR t.name LIKE ''%tmp%'' OR t.name LIKE ''%temp%'' OR t.name LIKE ''%stage%''
          )
          AND (ref_s.name NOT LIKE ''%stg%'' AND ref_s.name NOT LIKE ''%landing%'' AND ref_s.name NOT LIKE ''%raw%'' AND ref_s.name NOT LIKE ''%tmp%'' AND ref_s.name NOT LIKE ''%temp%'' AND ref_s.name NOT LIKE ''%stage%'')
          AND ref_obj.type IN (''P'', ''V'', ''FN'', ''IF'', ''TF'');
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + @DbName + ''',
        CASE
            WHEN @StagingCount = 0 THEN 3
            WHEN @RefCount = 0 THEN 3
            WHEN @RefCount BETWEEN 1 AND 2 THEN 2
            WHEN @RefCount BETWEEN 3 AND 5 THEN 1
            ELSE 0
        END,
        CASE
            WHEN @StagingCount = 0 THEN ''No staging objects found''
            WHEN @RefCount = 0 THEN ''Staging objects exist but no downstream references detected''
            ELSE ''Downstream references found: '' + @RefObjects
        END
    );
    ';
    EXEC sp_executesql @Sql;
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
            DECLARE @StagingCount INT = 0;
            DECLARE @RefCount INT = 0;
            DECLARE @RefObjects NVARCHAR(MAX) = '''';

            SELECT @StagingCount = COUNT(*)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%tmp%'' OR s.name LIKE ''%temp%'' OR s.name LIKE ''%stage%''
               OR t.name LIKE ''%stg%'' OR t.name LIKE ''%landing%'' OR t.name LIKE ''%raw%'' OR t.name LIKE ''%tmp%'' OR t.name LIKE ''%temp%'' OR t.name LIKE ''%stage%'';

            IF @StagingCount > 0
            BEGIN
                SELECT @RefCount = COUNT(DISTINCT referencing_id),
                       @RefObjects = STRING_AGG(QUOTENAME(OBJECT_SCHEMA_NAME(referencing_id)) + ''.'' + QUOTENAME(OBJECT_NAME(referencing_id)), '', '')
                FROM sys.sql_expression_dependencies sed
                JOIN sys.objects ref_obj ON sed.referencing_id = ref_obj.object_id
                JOIN sys.schemas ref_s ON ref_obj.schema_id = ref_s.schema_id
                WHERE sed.class = 1
                  AND sed.referencing_id IS NOT NULL
                  AND sed.referenced_id IN (
                      SELECT t.object_id FROM sys.tables t
                      JOIN sys.schemas s ON t.schema_id = s.schema_id
                      WHERE s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%tmp%'' OR s.name LIKE ''%temp%'' OR s.name LIKE ''%stage%''
                         OR t.name LIKE ''%stg%'' OR t.name LIKE ''%landing%'' OR t.name LIKE ''%raw%