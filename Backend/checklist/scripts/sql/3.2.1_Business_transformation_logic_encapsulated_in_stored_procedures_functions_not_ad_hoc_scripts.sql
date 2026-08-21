-- Checklist: Business/transformation logic encapsulated in stored procedures/functions (not ad-hoc scripts)
-- Scope: DATABASE
-- Scoring: 0: No user-defined stored procedures or functions found. 1: Procs/functions exist but contain no DML/transformation logic. 2: Procs/functions contain DML/transformation logic (proxy evidence). Full compliance requires human review.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @ProcCount INT = 0;
    DECLARE @DmlProcCount INT = 0;
    DECLARE @DmlProcs NVARCHAR(MAX) = '';

    SELECT @ProcCount = COUNT(*)
    FROM sys.objects
    WHERE type IN (''P'',''FN'',''IF'',''TF'')
      AND is_ms_shipped = 0;

    SELECT @DmlProcCount = COUNT(*)
    FROM sys.objects o
    JOIN sys.sql_modules m ON o.object_id = m.object_id
    WHERE o.type IN (''P'',''FN'',''IF'',''TF'')
      AND o.is_ms_shipped = 0
      AND (m.definition LIKE ''%INSERT INTO%'' OR m.definition LIKE ''%UPDATE %'' OR m.definition LIKE ''%DELETE FROM%'');

    SELECT @DmlProcs = STRING_AGG(o.name, '', '')
    FROM sys.objects o
    JOIN sys.sql_modules m ON o.object_id = m.object_id
    WHERE o.type IN (''P'',''FN'',''IF'',''TF'')
      AND o.is_ms_shipped = 0
      AND (m.definition LIKE ''%INSERT INTO%'' OR m.definition LIKE ''%UPDATE %'' OR m.definition LIKE ''%DELETE FROM%'');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE
            WHEN @ProcCount = 0 THEN 0
            WHEN @DmlProcCount = 0 THEN 1
            ELSE 2
        END,
        CASE
            WHEN @ProcCount = 0 THEN ''No user-defined stored procedures or functions found.''
            WHEN @DmlProcCount = 0 THEN ''Procs/functions exist but no DML/transformation logic detected.''
            ELSE ''Encapsulation evidence: '' + @DmlProcs
        END
    );
    ';
    EXEC sp_executesql @Sql;
    SET @DatabaseQueried = @DbName;
END
ELSE -- SQL Server / Azure SQL MI
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
            DECLARE @ProcCount INT = 0;
            DECLARE @DmlProcCount INT = 0;
            DECLARE @D