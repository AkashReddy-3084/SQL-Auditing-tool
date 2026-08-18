-- Checklist: No deprecated syntax/features (e.g., old-style joins, TEXT/NTEXT)
-- Scope: DATABASE
-- Scoring: 3: No deprecated data types and no old-style joins detected. 2: Deprecated data types detected, but no old-style joins. 1: Old-style joins detected, but no deprecated data types. 0: Both deprecated data types and old-style joins detected.

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
    DECLARE @DeprecatedCols NVARCHAR(MAX) = '''';
    DECLARE @OldJoins NVARCHAR(MAX) = '''';
    DECLARE @DepCount INT = 0;
    DECLARE @JoinCount INT = 0;

    SELECT @DepCount = COUNT(*) FROM sys.columns c
    JOIN sys.types t ON c.user_type_id = t.user_type_id
    WHERE t.name IN (''text'', ''ntext'', ''image'');

    SELECT @DeprecatedCols = STRING_AGG(o.name + ''.'' + c.name, ''; '')
    FROM sys.columns c
    JOIN sys.types t ON c.user_type_id = t.user_type_id
    JOIN sys.objects o ON c.object_id = o.object_id
    WHERE t.name IN (''text'', ''ntext'', ''image'');

    SELECT @JoinCount = COUNT(*) FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.is_ms_shipped = 0 AND m.definition LIKE ''%FROM% ,%'';

    SELECT @OldJoins = STRING_AGG(o.name, ''; '')
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.is_ms_shipped = 0 AND m.definition LIKE ''%FROM% ,%'';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + @DbName + ''',
        CASE
            WHEN @DepCount = 0 AND @JoinCount = 0 THEN 3
            WHEN @DepCount > 0 AND @JoinCount = 0 THEN 2
            WHEN @DepCount = 0 AND @JoinCount > 0 THEN 1
            ELSE 0
        END,
        CASE
            WHEN @DepCount = 0 AND @JoinCount = 0 THEN ''No deprecated features found''
            WHEN @DepCount > 0 AND @JoinCount = 0 THEN ''Deprecated types found