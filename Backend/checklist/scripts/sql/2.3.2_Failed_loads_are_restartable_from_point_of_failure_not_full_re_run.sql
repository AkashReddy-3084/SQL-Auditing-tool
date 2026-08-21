-- Checklist: Failed loads are restartable from point of failure (not full re-run)
-- Scope: DATABASE
-- Scoring: 0: No evidence of restartability logic. 1: Partial evidence (restart keywords in code or control tables/columns exist in isolation). 2: Good evidence (control tables with batch/status columns exist, but explicit restart procedures are missing). 3: Strong evidence (control tables with batch/status columns AND procedures explicitly reference them for filtering/restarting failed loads).
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
        DECLARE @ControlTables INT = 0;
        DECLARE @RestartCols INT = 0;
        DECLARE @RestartProcs INT = 0;
        DECLARE @Evidence NVARCHAR(MAX) = '''';

        SELECT @ControlTables = COUNT(*)
        FROM sys.tables t
        WHERE t.is_ms_shipped = 0
          AND (t.name LIKE ''%control%'' OR t.name LIKE ''%batch%'' OR t.name LIKE ''%load%'' OR t.name LIKE ''%staging%'');

        SELECT @RestartCols = COUNT(*)
        FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id
        WHERE t.is_ms_shipped = 0
          AND (t.name LIKE ''%control%'' OR t.name LIKE ''%batch%'' OR t.name LIKE ''%load%'')
          AND (c.name LIKE ''%batch%'' OR c.name LIKE ''%status%'' OR c.name LIKE ''%checkpoint%'' OR c.name LIKE ''%load%'');

        SELECT @RestartProcs = COUNT(*)
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
          AND (m.definition LIKE ''%batch%'' OR m.definition LIKE ''%restart%'' OR m.definition LIKE ''%resume%'' OR m.definition LIKE ''%failed%'' OR m.definition LIKE ''%checkpoint%'');

        IF @ControlTables > 0 AND @RestartCols > 0 AND @RestartProcs > 0
            SET @Evidence = ''Strong restartability evidence: '' + CAST(@ControlTables AS NVARCHAR) + '' control/batch tables, '' + CAST(@RestartCols AS NVARCHAR) + '' restart columns, '' + CAST(@RestartProcs AS NVARCHAR) + '' procedures with restart logic.'';
        ELSE IF @ControlTables > 0 AND @RestartCols > 0
            SET @Evidence = ''Partial evidence: '' + CAST(@ControlTables AS NVARCHAR) + '' control tables with '' + CAST(@RestartCols AS NVARCHAR) + '' restart columns, but no explicit restart procedures found.'';
        ELSE IF @RestartProcs > 0
            SET @Evidence = ''Partial evidence: '' + CAST(@RestartProcs AS NVARCHAR) + '' procedures contain restart keywords, but no control tables/columns found.'';
        ELSE
            SET @Evidence = ''No evidence of restartability logic found.'';

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        SELECT ''' + @DbName + ''',
               CASE
                   WHEN @ControlTables > 0 AND @RestartCols > 0 AND @RestartProcs > 0 THEN 3
                   WHEN @ControlTables > 0 AND @RestartCols > 0 THEN 2
                   WHEN @RestartProcs > 0 THEN 1
                   ELSE 0
               END,
               @Evidence;
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
            DECLARE @ControlTables INT = 0;
            DECLARE @RestartCols INT = 0;
            DECLARE @RestartProcs INT = 0;
            DECLARE @Evidence NVARCHAR(MAX) = '''';

            SELECT @ControlTables = COUNT(*)
            FROM sys.tables t
            WHERE t.is_ms_shipped = 0
              AND (t.name LIKE ''%control%'' OR t.name LIKE ''%batch%'' OR t.name LIKE ''%load%'' OR t.name LIKE ''%staging%'');

            SELECT @RestartCols = COUNT(*)
            FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            WHERE t.is_ms_shipped = 0
              AND (t.name LIKE ''%control%'' OR t.name LIKE ''%batch%'' OR t.name LIKE ''%load%'')
              AND (c.name LIKE ''%batch%'' OR c.name LIKE ''%status%'' OR c.name LIKE ''%checkpoint%'' OR c.name LIKE ''%load%'');

            SELECT @RestartProcs = COUNT(*)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE p.is_ms_shipped = 0
              AND (m.definition LIKE ''%batch%'' OR m.definition LIKE ''%restart%'' OR m.definition LIKE ''%resume%'' OR m.definition LIKE ''%failed%'' OR m.definition LIKE ''%checkpoint%'');

            IF @ControlTables > 0 AND @RestartCols > 0 AND @RestartProcs > 0
                SET @Evidence = ''Strong restartability evidence: '' + CAST(@ControlTables AS NVARCHAR) + '' control/batch tables, '' + CAST(@RestartCols AS NVARCHAR) + '' restart columns, '' + CAST(@RestartProcs AS NVARCHAR) + '' procedures with restart logic.'';
            ELSE IF @ControlTables > 0 AND @RestartCols > 0
                SET @Evidence = ''Partial evidence: '' + CAST(@ControlTables AS NVARCHAR) + '' control tables with '' + CAST(@RestartCols AS NVARCHAR) + '' restart columns, but no explicit restart procedures found.'';
            ELSE IF @RestartProcs > 0
                SET @Evidence = ''Partial evidence: '' + CAST(@RestartProcs AS NVARCHAR) + '' procedures contain