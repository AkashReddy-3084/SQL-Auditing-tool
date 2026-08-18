-- Checklist: Business definitions/rules documented and current
-- Scope: DATABASE
-- Scoring: 0: No documentation found. 1: <30% coverage. 2: 30-70% coverage or lacks business rule evidence. 3: >70% coverage with extended properties and constraints.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    DECLARE @TotalTables INT, @DocTables INT, @TotalCols INT, @DocCols INT, @Coverage DECIMAL(5,2);
    SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = 'U';
    SELECT @DocTables = COUNT(*) FROM sys.tables t
        WHERE type = 'U' AND EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.class = 1);
    SELECT @TotalCols = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.type = 'U';
    SELECT @DocCols = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id
        WHERE t.type = 'U' AND EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = c.object_id AND ep.minor_id = c.column_id AND ep.class = 2);
    
    SET @Coverage = CASE WHEN (@TotalTables + @TotalCols) = 0 THEN 100.0
        ELSE ((@DocTables + CAST(@DocCols AS DECIMAL)) * 100.0) / (@TotalTables + @TotalCols) END;
        
    DECLARE @DbScore INT = 0;
    IF @Coverage >= 70 SET @DbScore = 3;
    ELSE IF @Coverage >= 30 SET @DbScore = 2;
    ELSE IF @Coverage > 0 SET @DbScore = 1;
    
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@DbName, @DbScore, 'Coverage: ' + CAST(@Coverage AS NVARCHAR(10)) + '% (' + CAST(@DocTables AS NVARCHAR(10)) + ' tables, ' + CAST(@DocCols AS NVARCHAR(10)) + ' cols documented)');
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TotalTables INT, @DocTables INT, @TotalCols INT, @DocCols INT, @Coverage DECIMAL(5,2);
            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
            SELECT @DocTables = COUNT(*) FROM sys.tables t
                WHERE type = ''U'' AND EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.class = 1);
            SELECT @TotalCols = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.type = ''U'';
            SELECT @DocCols = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id
                WHERE t.type = ''U'' AND EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = c.object_id AND ep.minor_id = c.column_id AND ep.class