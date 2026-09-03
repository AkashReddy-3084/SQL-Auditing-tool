SET NOCOUNT ON;

DECLARE @Result varchar(10);
DECLARE @Score int = 0;
DECLARE @DatabaseQueried nvarchar(max) = N'None';
DECLARE @Finding nvarchar(max) = N'No database found to be queried';

DECLARE @IsAzure bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#FactGrain') IS NOT NULL DROP TABLE #FactGrain;
CREATE TABLE #FactGrain (
    DatabaseName sysname NOT NULL,
    SchemaName sysname NOT NULL,
    TableName sysname NOT NULL,
    HasUnique bit NOT NULL
);

IF @IsAzure = 1
BEGIN
    INSERT INTO #FactGrain (DatabaseName, SchemaName, TableName, HasUnique)
    SELECT
        DB_NAME(),
        s.name,
        t.name,
        CASE WHEN EXISTS (
            SELECT 1
            FROM sys.indexes i
            WHERE i.object_id = t.object_id
              AND i.is_unique = 1
              AND i.is_hypothetical = 0
              AND i.is_disabled = 0
        ) THEN 1 ELSE 0 END
    FROM sys.tables t
    INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND (
            LOWER(t.name) LIKE N'fact%'
         OR LOWER(t.name) LIKE N'%_fact'
         OR LOWER(t.name) LIKE N'%_fact_%'
         OR LOWER(t.name) LIKE N'%fact'
      );
END
ELSE
BEGIN
    DECLARE @db sysname;
    DECLARE @sql nvarchar(max);
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name
        FROM sys.databases
        WHERE database_id > 4
          AND state_desc = N'ONLINE'
          AND HAS_DBACCESS(name) = 1
          AND is_read_only = 0
          AND name NOT IN (N'distribution', N'SSISDB');

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
INSERT INTO #FactGrain (DatabaseName, SchemaName, TableName, HasUnique)
SELECT
    N' + QUOTENAME(@db, '''') + N',
    s.name,
    t.name,
    CASE WHEN EXISTS (
        SELECT 1
        FROM ' + QUOTENAME(@db) + N'.sys.indexes i
        WHERE i.object_id = t.object_id
          AND i.is_unique = 1
          AND i.is_hypothetical = 0
          AND i.is_disabled = 0
    ) THEN 1 ELSE 0 END
FROM ' + QUOTENAME(@db) + N'.sys.tables t
INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND (
        LOWER(t.name) LIKE N''fact%''
     OR LOWER(t.name) LIKE N''%_fact''
     OR LOWER(t.name) LIKE N''%_fact_%''
     OR LOWER(t.name) LIKE N''%fact''
  );';
        BEGIN TRY
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            -- skip inaccessible databases
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @db;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @FactCount int = (SELECT COUNT(*) FROM #FactGrain);
DECLARE @Enforced int = (SELECT COUNT(*) FROM #FactGrain WHERE HasUnique = 1);
DECLARE @Missing int = (SELECT COUNT(*) FROM #FactGrain WHERE HasUnique = 0);
DECLARE @Pct decimal(5,2) = CASE WHEN @FactCount = 0 THEN 100.00 ELSE CAST(100.0 * @Enforced / @FactCount AS decimal(5,2)) END;

DECLARE @DbList nvarchar(max);

IF @IsAzure = 1
BEGIN
    SET @DbList = QUOTENAME(DB_NAME());
END
ELSE
BEGIN
    SET @DbList = (
        SELECT ISNULL(STUFF((
            SELECT N', ' + QUOTENAME(name)
            FROM sys.databases
            WHERE database_id > 4
              AND state_desc = N'ONLINE'
              AND HAS_DBACCESS(name) = 1
              AND is_read_only = 0
              AND name NOT IN (N'distribution', N'SSISDB')
            ORDER BY name
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, N''), N'')
    );
END

IF (@IsAzure = 0 AND (@DbList IS NULL OR @DbList = N''))
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
END
ELSE IF @FactCount = 0
BEGIN
    SET @Score = 3;
    SET @DatabaseQueried = @DbList;
    SET @Finding = N'No candidate fact tables (name pattern fact*/%fact%) found in queried user database(s); no duplicate-grain risk detected by naming convention.';
END
ELSE IF @Missing = 0
BEGIN
    SET @Score = 3;
    SET @DatabaseQueried = @DbList;
    SET @Finding = N'All ' + CAST(@FactCount AS varchar(11)) + N' candidate fact table(s) enforce uniqueness via PRIMARY KEY or UNIQUE index/constraint.';
END
ELSE
BEGIN
    DECLARE @Sample nvarchar(max) = (
        SELECT ISNULL(STUFF((
            SELECT TOP (8) N', ' + QUOTENAME(DatabaseName) + N'.' + QUOTENAME(SchemaName) + N'.' + QUOTENAME(TableName)
            FROM #FactGrain
            WHERE HasUnique = 0
            ORDER BY DatabaseName, SchemaName, TableName
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, N''), N'')
    );

    IF @Pct >= 95.0 SET @Score = 2;
    ELSE IF @Pct >= 75.0 SET @Score = 1;
    ELSE SET @Score = 0;

    SET @DatabaseQueried = @DbList;
    SET @Finding = N'Found ' + CAST(@Missing AS varchar(11)) + N' of ' + CAST(@FactCount AS varchar(11))
        + N' candidate fact table(s) without PRIMARY KEY/UNIQUE enforcement ('
        + CONVERT(varchar(12), @Pct) + N'% enforced). Examples: ' + @Sample + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;