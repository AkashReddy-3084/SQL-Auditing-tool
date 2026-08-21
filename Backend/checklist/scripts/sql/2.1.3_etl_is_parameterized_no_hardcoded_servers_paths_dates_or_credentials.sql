-- Checklist: ETL is parameterized (no hardcoded servers, paths, dates, or credentials)
-- Scope: DATABASE
-- Scoring: 3: No hardcoded values detected. 2: 1-2 instances found. 1: 3-5 instances found. 0: >5 instances or credentials/servers hardcoded.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
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

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @Count INT;
    DECLARE @Objects NVARCHAR(MAX);
    SELECT @Count = COUNT(DISTINCT o.object_id),
           @Objects = STRING_AGG(SCHEMA_NAME(o.schema_id) + ''.'' + o.name, '', '')
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'')
      AND o.is_ms_shipped = 0
      AND SCHEMA_NAME(o.schema_id) <> ''sys''
      AND m.definition IS NOT NULL
      AND (
        m.definition LIKE ''%sa%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%password%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%pwd%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%secret%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%\\%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%192.168.%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%10.%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%172.16.%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%localhost%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%C:\%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%D:\%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%20[0-9][0-9]-[0-1][0-9]-[0-3][0-9]%'' COLLATE Latin1_General_CI_AI
        OR m.definition LIKE ''%''''20[0-9][0-9]%'' COLLATE Latin1_General_CI_AI
      );
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + @DbName + ''',
        CASE 
            WHEN @Count = 0 THEN 3
            WHEN @Count <= 2 THEN 2
            WHEN @Count <= 5 THEN 1
            ELSE 0
        END,
        CASE 
            WHEN @Count = 0 THEN ''No hardcoded values found''
            ELSE ''Hardcoded values detected in: '' + ISNULL(@Objects, ''Unknown'')
        END
    );';
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
            DECLARE @Count INT;
            DECLARE @Objects NVARCHAR(MAX);
            SELECT @Count = COUNT(DISTINCT o.object_id),
                   @Objects = STRING_AGG(SCHEMA_NAME(o.schema_id) + ''.'' + o.name, '', '')
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'')
              AND o