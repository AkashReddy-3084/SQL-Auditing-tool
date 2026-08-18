-- Checklist: Business rule validation applied (domain rules, ranges)
-- Scope: DATABASE
-- Scoring: 0: No check constraints or validation logic found. 1: 1-5 check constraints or 1-3 validation procs. 2: 6-20 check constraints or 4-10 validation procs. 3: >20 check constraints or >10 validation procs.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
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
    BEGIN TRY
        SET @Sql = N'
        DECLARE @ConstraintCount INT = 0;
        DECLARE @ValidationProcCount INT = 0;
        DECLARE @FindingText NVARCHAR(MAX) = '''';

        SELECT @ConstraintCount = COUNT(*)
        FROM sys.check_constraints cc
        JOIN sys.tables t ON cc.parent_object_id = t.object_id
        WHERE t.is_ms_shipped = 0;

        SELECT @ValidationProcCount = COUNT(*)
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
          AND m.definition IS NOT NULL
          AND (m.definition LIKE ''%IF %'' OR m.definition LIKE ''%THROW%'' OR m.definition LIKE ''%RAISERROR%'' OR m.definition LIKE ''%TRY%'' OR m.definition LIKE ''%CATCH%'');

        SET @FindingText = ''Check constraints: '' + CAST(@ConstraintCount AS NVARCHAR(10)) + ''; Validation procs: '' + CAST(@ValidationProcCount AS NVARCHAR(10));

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + @DbName + ''', 
                CASE 
                    WHEN @ConstraintCount = 0 AND @ValidationProcCount = 0 THEN 0
                    WHEN (@ConstraintCount BETWEEN 1 AND 5) OR (@ValidationProcCount BETWEEN 1 AND 3) THEN 1
                    WHEN (@ConstraintCount BETWEEN 6 AND 20) OR (@ValidationProcCount BETWEEN 4 AND 10) THEN 2
                    ELSE 3 
                END,
                @FindingText);
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
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
            DECLARE @ConstraintCount INT = 0;
            DECLARE @ValidationProcCount INT = 0;
            DECLARE