-- Checklist: Constraints are TRUSTED (not disabled/untrusted, which hurts the optimizer)
-- Scope: DATABASE
-- Scoring: 3: No untrusted/disabled constraints. 2: 1-4 untrusted/disabled constraints. 1: 5-9 untrusted/disabled constraints. 0: 10+ untrusted/disabled constraints.

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

IF @EngineEdition <> 5
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
DECLARE @Count INT;
DECLARE @List NVARCHAR(MAX);

SELECT @Count = COUNT(*),
       @List = STRING_AGG(ConstraintDetail, '','')
FROM (
    SELECT SCHEMA_NAME(c.schema_id) + ''.'' + c.name + '' on '' + SCHEMA_NAME(o.schema_id) + ''.'' + o.name AS ConstraintDetail
    FROM sys.check_constraints c
    JOIN sys.objects o ON c.parent_object_id = o.object_id
    WHERE c.is_disabled = 1 OR c.is_not_trusted = 1
    UNION ALL
    SELECT SCHEMA_NAME(f.schema_id) + ''.'' + f.name + '' on '' + SCHEMA_NAME(o.schema_id) + ''.'' + o.name
    FROM sys.foreign_keys f
    JOIN sys.objects o ON f.parent_object_id = o.object_id
    WHERE f.is_disabled = 1 OR f.is_not_trusted = 1
) AS Untrusted;

INSERT INTO #DbResults (DbName, DbScore, Finding)
VALUES (
    ''' + @DbName + ''',
    CASE 
        WHEN @Count = 0 THEN 3
        WHEN @Count BETWEEN 1 AND 4 THEN 2
        WHEN @Count BETWEEN 5 AND 9 THEN 1
        ELSE 0 
    END,
    CASE 
        WHEN @Count = 0 THEN ''All constraints are trusted and enabled.''
        ELSE ''Found '' + CAST(@Count AS NVARCHAR(10)) + '' untrusted/disabled constraint(s): '' + ISNULL(@List, ''None listed'')
    END
);';

            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END
ELSE
BEGIN
    BEGIN TRY
        DECLARE @Count INT;
        DECLARE @List NVARCHAR(MAX);
        DECLARE @CurrentDbName NVARCHAR(128) = DB_NAME();

        SELECT @Count = COUNT(*),