-- Checklist: Dates: valid ranges; consistent handling; no invalid future dates where prohibited
-- Scope: DATABASE
-- Scoring: 0: No CHECK constraints on date columns or >50% uncovered. 1: Some constraints exist but <50% coverage or weak logic. 2: >50% coverage with valid range/future-date constraints. 3: 100% coverage with explicit range/future-date constraints on all date columns.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    DECLARE @DateCols TABLE (
        TableName NVARCHAR(128),
        ColumnName NVARCHAR(128),
        HasCheckConstraint BIT,
        ConstraintDef NVARCHAR(MAX)
    );

    INSERT INTO @DateCols
    SELECT
        t.name AS TableName,
        c.name AS ColumnName,
        CASE WHEN cc.name IS NOT NULL THEN 1 ELSE 0 END AS HasCheckConstraint,
        sm.definition AS ConstraintDef
    FROM sys.columns c
    JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.types tp ON c.user_type_id = tp.user_type_id
    LEFT JOIN sys.check_constraints cc ON cc.parent_column_id = c.column_id AND cc.parent_object_id = c.object_id
    LEFT JOIN sys.sql_modules sm ON sm.object_id = cc.object_id
    WHERE tp.name IN (''date'', ''datetime'', ''datetime2'', ''datetimeoffset'', ''smalldatetime'')
      AND t.type = ''U''
      AND t.is_ms_shipped = 0;

    DECLARE @TotalCols INT = (SELECT COUNT(*) FROM @DateCols);
    DECLARE @CoveredCols INT = (SELECT COUNT(*) FROM @DateCols WHERE HasCheckConstraint = 1);
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '';

    IF @TotalCols = 0
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''No date columns found in user tables.'';
    END
    ELSE
    BEGIN
        DECLARE @CoveragePct FLOAT = CAST(@CoveredCols AS FLOAT) / @TotalCols * 100;
        DECLARE @QualityCols INT = (SELECT COUNT(*) FROM @DateCols WHERE HasCheckConstraint = 1 AND (ConstraintDef LIKE ''%>='' OR ConstraintDef LIKE ''%<='' OR ConstraintDef LIKE ''%BETWEEN%'' OR ConstraintDef LIKE ''%GETDATE%'' OR ConstraintDef LIKE ''%CURRENT_TIMESTAMP%''));

        IF @CoveragePct >= 100 AND @QualityCols = @TotalCols SET @DbScore = 3;
        ELSE IF @CoveragePct >= 50 AND @QualityCols >= @TotalCols * 0.5 SET @DbScore = 2;
        ELSE IF @CoveragePct > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        DECLARE @Uncovered NVARCHAR(MAX) = (SELECT STRING_AGG(TableName + ''.'' + ColumnName, '', '') FROM @DateCols WHERE HasCheckConstraint = 0);
        SET @DbFinding = ''Total date columns: '' + CAST(@TotalCols AS NVARCHAR) + ''. Covered by CHECK constraints: '' + CAST(@CoveredCols AS NVARCHAR) + '' ('' + CAST(ROUND(@CoveragePct, 0) AS NVARCHAR) + ''%). '';
        IF @Uncovered IS NOT NULL SET @DbFinding = @DbFinding + ''Uncovered: '' + @Uncovered;
        ELSE SET @DbFinding = @DbFinding + ''All date columns have CHECK constraints.'';
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate through user databases
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
            DECLARE @DateCols TABLE (
                TableName NVARCHAR(128),
                ColumnName NVARCHAR(128),
                HasCheckConstraint BIT,
                ConstraintDef NVARCHAR(MAX)
            );

            INSERT INTO @DateCols
            SELECT
                t.name AS TableName,
                c.name AS ColumnName,
                CASE WHEN cc.name IS NOT NULL THEN 1 ELSE 0 END AS HasCheckConstraint,
                sm.definition AS ConstraintDef
            FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.types tp ON c.user_type_id = tp.user_type_id
            LEFT JOIN sys.check_constraints cc ON cc.parent_column_id = c.column_id AND cc.parent_object_id = c.object_id
            LEFT JOIN sys.sql_modules sm ON sm.object_id = cc.object_id
            WHERE tp.name IN (''date'', ''datetime'', ''datetime2'', ''datetimeoffset'', ''smalldatetime'')
              AND t.type = ''U