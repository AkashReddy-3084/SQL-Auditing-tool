-- Checklist: Identifiers / Keys: uniqueness verified; format consistent; no nulls in keys
-- Scope: DATABASE
-- Scoring: 3: All user tables have PK/Unique enforcement and 0 nullable key columns. 2: <=3 tables missing enforcement or <=3 nullable key columns. 1: >3 but <=10 tables/columns with issues. 0: >10 tables/columns with issues.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQLDB = 1
BEGIN
    DECLARE @CurDbName NVARCHAR(128) = DB_NAME();
    DECLARE @TotalTables INT, @TablesWithKeys INT, @NullableKeyCols INT;
    DECLARE @MissingTablesList NVARCHAR(MAX), @NullableColsList NVARCHAR(MAX);
    DECLARE @DbScore INT, @DbFinding NVARCHAR(MAX);

    SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = 'U';

    SELECT @TablesWithKeys = COUNT(DISTINCT t.object_id)
    FROM sys.tables t
    INNER JOIN sys.indexes i ON t.object_id = i.object_id
    WHERE t.type = 'U' AND (i.is_primary_key = 1 OR i.is_unique = 1);

    SELECT @NullableKeyCols = COUNT(DISTINCT c.object_id)
    FROM sys.columns c
    INNER JOIN sys.indexes i ON c.object_id = i.object_id
    INNER JOIN sys.index_columns ic ON c.object_id = ic.object_id AND c.column_id = ic.column_id AND i.index_id = ic.index_id
    WHERE c.is_nullable = 1 AND (i.is_primary_key = 1 OR i.is_unique = 1);

    SELECT @MissingTablesList = STRING_AGG(s.name + '.' + t.name, ', ')
    FROM sys.tables t
    LEFT JOIN sys.indexes i ON t.object_id = i.object_id AND (i.is_primary_key = 1 OR i.is_unique = 1)
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.type = 'U' AND i.index_id IS NULL;

    SELECT @NullableColsList = STRING_AGG(s.name + '.' + t.name + '.' + c.name, ', ')
    FROM sys.columns c
    INNER JOIN sys.indexes i ON c.object_id = i.object_id AND (i.is_primary_key = 1 OR i.is_unique = 1)
    INNER JOIN sys.index_columns ic ON c.object_id = ic.object_id AND c.column_id = ic.column_id AND i.index_id = ic.index_id
    JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE c.is_nullable = 1;

    IF @TotalTables = 0
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = 'No user tables found';
    END
    ELSE
    BEGIN
        DECLARE @MissingCount INT = @TotalTables - @TablesWithKeys;
        IF @MissingCount = 0 AND @NullableKeyCols = 0
            SET @DbScore = 3;
        ELSE IF @MissingCount <= 3 AND @NullableKeyCols <= 3
            SET @DbScore = 2;
        ELSE IF @MissingCount <= 10 AND @NullableKeyCols <= 10
            SET @DbScore = 1;
        ELSE
            SET @DbScore = 0;

        SET @DbFinding = '';
        IF @MissingCount > 0
            SET @DbFinding = @DbFinding + 'Tables missing PK/Unique: ' + ISNULL(@MissingTablesList, 'None') + '; ';
        IF @NullableKeyCols > 0
            SET @DbFinding = @DbFinding + 'Nullable key columns: ' + ISNULL(@NullableColsList, 'None') + '; ';
        IF @DbFinding = ''
            SET @DbFinding = 'All keys verified';
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@CurDbName, @DbScore, @DbFinding);
END
ELSE
BEGIN
    DECLARE @DbName NVARCHAR(256);
    DECLARE @Sql NVARCHAR(MAX);
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
            DECLARE @TotalTables INT, @TablesWithKeys INT, @NullableKeyCols INT;
            DECLARE @MissingTablesList NVARCHAR(MAX), @NullableColsList NVARCHAR(MAX);
            DECLARE @DbScore INT, @DbFinding NVARCHAR(MAX);

            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';

            SELECT @TablesWithKeys = COUNT(DISTINCT t.object_id)
            FROM sys.tables t
            INNER JOIN sys.indexes i ON t.object_id = i.object_id
            WHERE t.type = ''U'' AND (i.is_primary_key = 1 OR i.is_unique = 1);

            SELECT @NullableKeyCols = COUNT(DISTINCT c.object_id)
            FROM sys.columns c
            INNER JOIN sys.indexes i ON c.object_id = i.object_id
            INNER JOIN sys.index_columns ic ON c.object_id = ic.object_id AND c.column_id = ic.column_id AND i.index_id = ic.index_id
            WHERE c.is_nullable = 1 AND (i.is_primary_key = 1 OR i.is_unique = 1);

            SELECT @MissingTablesList = STRING_AGG(s.name + ''.'' + t.name, '', '')
            FROM sys.tables t
            LEFT JOIN sys.indexes i ON t.object_id = i.object_id AND (i.is_primary_key = 1 OR i.is_unique = 1