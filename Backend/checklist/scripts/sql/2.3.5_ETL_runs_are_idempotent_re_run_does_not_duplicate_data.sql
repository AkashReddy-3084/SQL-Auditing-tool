-- Checklist: ETL runs are idempotent (re-run does not duplicate data)
-- Scope: DATABASE
-- Scoring: 3=Strong idempotent patterns in >=80% of ETL objects; 2=Patterns in >=50%; 1=Patterns in >=20%; 0=<20% or no ETL objects. NOTE: This script provides automated evidence. Full compliance requires human review.

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
    SET @Sql = N'
    DECLARE @TotalETL INT = 0;
    DECLARE @IdempotentETL INT = 0;

    SELECT @TotalETL = COUNT(*)
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE p.is_ms_shipped = 0
      AND m.definition IS NOT NULL
      AND (p.name LIKE ''%ETL%'' OR p.name LIKE ''%Load%'' OR p.name LIKE ''%Sync%'' OR p.name LIKE ''%Import%'' OR p.name LIKE ''%Staging%'' OR p.name LIKE ''%DW%'' OR p.name LIKE ''%Mart%'');

    SELECT @IdempotentETL = COUNT(*)
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE p.is_ms_shipped = 0
      AND m.definition IS NOT NULL
      AND (p.name LIKE ''%ETL%'' OR p.name LIKE ''%Load%'' OR p.name LIKE ''%Sync%'' OR p.name LIKE ''%Import%'' OR p.name LIKE ''%Staging%'' OR p.name LIKE ''%DW%'' OR p.name LIKE ''%Mart%'')
      AND (m.definition LIKE ''%MERGE%'' OR m.definition LIKE ''%TRUNCATE%'' OR m.definition LIKE ''%DELETE%'' OR m.definition LIKE ''%UPSERT%'' OR m.definition LIKE ''%BATCH%'' OR m.definition LIKE ''%LOAD_DATE%'' OR m.definition LIKE ''%ROWVERSION%'');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + @DbName + ''',
        CASE
            WHEN @TotalETL = 0 THEN 0
            WHEN CAST(@IdempotentETL AS FLOAT) / @TotalETL >= 0.8 THEN 3
            WHEN CAST(@IdempotentETL AS FLOAT) / @TotalETL >= 0.5 THEN 2
            WHEN CAST(@IdempotentETL AS FLOAT) / @TotalETL >= 0.2 THEN 1
            ELSE 0
        END,
        ''Total ETL objects: '' + CAST(@TotalETL AS NVARCHAR(10)) + ''; Idempotent patterns found in: '' + CAST(@IdempotentETL AS NVARCHAR(10))
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
            DECLARE @TotalETL INT = 0;
            DECLARE @IdempotentETL INT = 0;

            SELECT @TotalETL = COUNT(*)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE p.is_ms_shipped = 0
              AND m.definition IS NOT NULL
              AND (p.name LIKE ''%ETL%'' OR p.name LIKE ''%Load%'' OR p.name LIKE ''%Sync%'' OR p.name LIKE ''%Import%'' OR p.name LIKE ''%Staging%'' OR p.name LIKE ''%DW%'' OR p.name LIKE ''%Mart%'');

            SELECT @IdempotentETL = COUNT(*)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE p.is_ms_shipped = 0
              AND m.definition IS NOT NULL
              AND (p.name LIKE ''%ETL%'' OR p.name LIKE ''%Load%'' OR p.name LIKE ''%Sync%'' OR p.name LIKE ''%Import%