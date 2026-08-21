-- Checklist: Naming conventions consistent for tables, columns, and schemas
-- Scope: DATABASE
-- Scoring: 0: >20% violations; 1: 5-20% violations; 2: <5% violations; 3: 0% violations. NOTE: Proxy check; full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

SET @Sql = N'
DECLARE @Total INT, @Violations INT, @ViolationNames NVARCHAR(MAX);
SELECT @Total = COUNT(*) FROM (
    SELECT name FROM sys.schemas WHERE is_ms_shipped = 0
    UNION ALL
    SELECT name FROM sys.tables WHERE is_ms_shipped = 0
    UNION ALL
    SELECT c.name FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.is_ms_shipped = 0
) AS AllNames;

SELECT @Violations = COUNT(*), @ViolationNames = STRING_AGG(name, '','')
FROM (
    SELECT name FROM sys.schemas WHERE is_ms_shipped = 0 AND (PATINDEX(''%[^a-zA-Z0-9_]%'', name) > 0 OR (name <> LOWER(name) AND name <> UPPER(name)))
    UNION ALL
    SELECT name FROM sys.tables WHERE is_ms_shipped = 0 AND (PATINDEX(''%[^a-zA-Z0-9_]%'', name) > 0 OR (name <> LOWER(name) AND name <> UPPER(name)))
    UNION ALL
    SELECT c.name FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.is_ms_shipped = 0 AND (PATINDEX(''%[^a-zA-Z0-9_]%'', c.name) > 0 OR (c.name <> LOWER(c.name) AND c.name <> UPPER(c.name)))
) AS V;

INSERT INTO #DbResults (DbName, DbScore, Finding)
VALUES (
    @DbName,
    CASE
        WHEN ISNULL(@Total, 0) = 0 THEN 3
        WHEN ISNULL(@Violations, 0) = 0 THEN 3
        WHEN CAST(ISNULL(@Violations, 0) AS FLOAT) / @Total < 0.05 THEN 2
        WHEN CAST(ISNULL(@Violations, 0) AS FLOAT) / @Total < 0.20 THEN 1
        ELSE 0
    END,
    CASE
        WHEN ISNULL(@Violations, 0) = 0 THEN ''No naming convention violations found''
        ELSE ''Found '' + CAST(@Violations AS NVARCHAR) + '' violations out of '' + CAST(@Total AS NVARCHAR) + '' objects: '' + LEFT(@ViolationNames, 200)
    END
);';

IF @EngineEdition = 5
BEGIN
    SET @DbName = DB_NAME();
    EXEC sp_executesql @Sql, N'@DbName NVARCHAR(128)', @DbName = @DbName;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';' + @Sql;
            EXEC sp_executesql @Sql, N'@DbName NVARCHAR(128)', @DbName = @DbName;
        END TRY
        BEGIN CATCH