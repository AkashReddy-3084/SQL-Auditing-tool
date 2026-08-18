-- Checklist: TRY...CATCH with proper error raising/logging (THROW/RAISERROR)
-- Scope: DATABASE
-- Scoring: 0: No TRY...CATCH found. 1: TRY...CATCH found but <50% include THROW/RAISERROR. 2: 50-99% include THROW/RAISERROR. 3: >=99% include THROW/RAISERROR.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
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
    SET @Sql = N'
    DECLARE @TryCatchCount INT = 0;
    DECLARE @ErrorRaiseCount INT = 0;
    DECLARE @MissingErrorRaise NVARCHAR(MAX) = ''None'';

    SELECT 
        @TryCatchCount = COUNT(*),
        @ErrorRaiseCount = SUM(CASE WHEN definition LIKE ''%THROW%'' OR definition LIKE ''%RAISERROR%'' THEN 1 ELSE 0 END)
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.type IN (''P'', ''PC'', ''TF'', ''IF'', ''FS'')
      AND o.is_ms_shipped = 0
      AND definition LIKE ''%TRY%''
      AND definition LIKE ''%CATCH%'';

    IF @TryCatchCount = 0
    BEGIN
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', 0, ''No TRY...CATCH blocks found in any procedures.'');
    END
    ELSE
    BEGIN
        SELECT @MissingErrorRaise = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '')
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'', ''PC'', ''TF'', ''IF'', ''FS'')
          AND o.is_ms_shipped = 0
          AND m.definition LIKE ''%TRY%''
          AND m.definition LIKE ''%CATCH%''
          AND m.definition NOT LIKE ''%THROW%''
          AND m.definition NOT LIKE ''%RAISERROR%'';

        IF @MissingErrorRaise IS NULL SET @MissingErrorRaise = ''None'';

        DECLARE @DbScore INT;
        DECLARE @Ratio FLOAT = CAST(@ErrorRaiseCount AS FLOAT) / CAST(@TryCatchCount AS FLOAT);
        IF @Ratio >= 0.95 SET @DbScore = 3;
        ELSE IF @Ratio >= 0.50 SET @DbScore = 2;
        ELSE SET @DbScore = 1;

        INSERT INTO #DbResults (DbName, DbScore, Finding) 
        VALUES (''' + @DbName + ''', @DbScore, CAST(@TryCatchCount AS NVARCHAR) + '' TRY...CATCH blocks found. '' + CAST(@ErrorRaiseCount AS NVARCHAR) + '' include THROW/RAISERROR. Missing: '' + @MissingErrorRaise);
    END';
    EXEC sp_executesql @Sql;
    SET @DatabaseQueried = @DbName;
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
            DECLARE @TryCatchCount INT = 0;
            DECLARE @ErrorRaiseCount INT = 0;
            DECLARE @MissingErrorRaise NVARCHAR(MAX) = ''None'';

            SELECT 
                @TryCatchCount = COUNT(*),
                @ErrorRaiseCount = SUM(CASE WHEN definition LIKE ''%THROW%'' OR definition LIKE ''%RAISERROR%'' THEN 1 ELSE 0 END)
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'', ''PC'', ''TF'', ''IF'', ''FS'')
              AND o.is_ms_shipped = 0
              AND definition LIKE ''%TRY%''
              AND definition LIKE ''%CATCH%'';

            IF @TryCatchCount = 0
            BEGIN
                INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', 0, ''No TRY...CATCH blocks found in any procedures.'');
            END
            ELSE
            BEGIN
                SELECT @MissingErrorRaise = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '')
                FROM sys.sql_modules m
                JOIN sys.objects o ON m.object_id = o.object_id
                WHERE o.type IN (''P'', ''PC'', ''TF'', ''IF'', ''FS'')
                  AND o.is_ms_shipped = 0
                  AND m.definition LIKE ''%TRY%''
                  AND m.definition LIKE ''%CATCH%''
                  AND m.definition NOT LIKE ''%THROW%''
                  AND m.definition NOT LIKE ''%RAISERROR%'';

                IF @MissingErrorRaise IS NULL SET @MissingErrorRaise = ''None'';

                DECLARE @DbScore INT;
                DECLARE @Ratio FLOAT = CAST(@ErrorRaiseCount AS FLOAT) / CAST(@TryCatchCount AS FLOAT);
                IF @Ratio >= 0.95 SET @DbScore = 3;
                ELSE IF @Ratio >= 0.50 SET @DbScore = 2;
                ELSE SET @DbScore = 1;

                INSERT INTO #DbResults (DbName, DbScore, Finding) 
                VALUES (''' + @DbName + ''', @DbScore, CAST(@TryCatchCount AS NVARCHAR) + '' TRY...CATCH blocks found. '' + CAST