-- Checklist: Dynamic SQL, where used, is parameterized (sp_executesql) — no injection risk
-- Scope: DATABASE
-- Scoring: 3: No non-compliant dynamic SQL found. 2: 1-3 procedures use EXEC/EXECUTE without sp_executesql. 1: 4-10 procedures. 0: >10 procedures.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @NonCompliantCount INT;
    DECLARE @NonCompliantList NVARCHAR(MAX);

    SELECT @NonCompliantCount = COUNT(*),
           @NonCompliantList = STRING_AGG(SCHEMA_NAME(p.schema_id) + ''.'' + p.name, '', '')
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE p.is_ms_shipped = 0
      AND (m.definition LIKE ''%EXEC%'' OR m.definition LIKE ''%EXECUTE%'')
      AND m.definition NOT LIKE ''%sp_executesql%'';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + @DbName + ''',
        CASE 
            WHEN @NonCompliantCount = 0 THEN 3
            WHEN @NonCompliantCount BETWEEN 1 AND 3 THEN 2
            WHEN @NonCompliantCount BETWEEN 4 AND 10 THEN 1
            ELSE 0
        END,
        ISNULL(@NonCompliantList, ''No non-compliant objects found'')
    );
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
            DECLARE @NonCompliantCount INT;
            DECLARE @NonCompliantList NVARCHAR(MAX);

            SELECT @NonCompliantCount = COUNT(*),
                   @NonCompliantList = STRING_AGG(SCHEMA_NAME(p.schema_id) + ''.'' + p.name, '', '')
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE p.is_ms_shipped = 0
              AND (m.definition LIKE ''%EXEC%'' OR m.definition LIKE ''%EXECUTE%'')
              AND m.definition NOT LIKE ''%sp_executesql%'';

            INSERT INTO #DbResults (DbName, DbScore,