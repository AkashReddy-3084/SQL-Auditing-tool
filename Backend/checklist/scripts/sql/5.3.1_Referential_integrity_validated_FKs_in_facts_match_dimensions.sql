-- Checklist: Referential integrity validated (FKs in facts match dimensions)
-- Scope: DATABASE
-- Scoring: 0=No FKs or facts lack FKs to dims; 1=FKs exist but none link facts to dims; 2=Some facts have FKs to dims; 3=All facts have FKs to dims

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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalFKs INT = 0;
    DECLARE @FactCount INT = 0;
    DECLARE @FactWithFKCount INT = 0;

    SELECT @TotalFKs = COUNT(*) FROM sys.foreign_keys;

    SELECT @FactCount = COUNT(*)
    FROM sys.tables t
    WHERE t.is_ms_shipped = 0
      AND (t.name LIKE ''Fact%'' OR t.name LIKE ''F_%'');

    SELECT @FactWithFKCount = COUNT(DISTINCT fk.parent_object_id)
    FROM sys.foreign_keys fk
    JOIN sys.tables t ON fk.parent_object_id = t.object_id
    JOIN sys.tables ref_t ON fk.referenced_object_id = ref_t.object_id
    WHERE t.is_ms_shipped = 0
      AND (t.name LIKE ''Fact%'' OR t.name LIKE ''F_%'')
      AND (ref_t.name LIKE ''Dim%'' OR ref_t.name LIKE ''D_%'');

    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    IF @TotalFKs = 0
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''No foreign keys defined in the database.'';
    END
    ELSE IF @FactCount = 0
    BEGIN
        SET @DbScore = 1;
        SET @DbFinding = ''No fact tables identified (naming: Fact% or F_%), but '' + CAST(@TotalFKs AS NVARCHAR) + '' FK(s) exist.'';
    END
    ELSE IF @FactWithFKCount = 0
    BEGIN
        SET @DbScore = 1;
        SET @DbFinding = '''' + CAST(@FactCount AS NVARCHAR) + '' fact table(s) found, but none have FKs referencing dimension tables.'';
    END
    ELSE IF @FactWithFKCount < @FactCount
    BEGIN
        SET @DbScore = 2;
        SET @DbFinding = '''' + CAST(@FactWithFKCount AS NVARCHAR) + '' of '' + CAST(@FactCount AS NVARCHAR) + '' fact tables have FKs referencing dimension tables.'';
    END
    ELSE
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''All '' + CAST(@FactCount AS NVARCHAR) + '' fact tables have FKs referencing dimension tables.'';
    END

    SELECT @DbScore AS DbScore, @DbFinding AS Finding;
    ';
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM