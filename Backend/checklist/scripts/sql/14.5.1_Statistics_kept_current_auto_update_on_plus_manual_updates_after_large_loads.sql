-- Checklist: 14.5.1 Statistics kept current (auto-update on, plus manual updates after large loads)
-- Scope: DATABASE
-- Scoring: 3: AUTO_UPDATE_STATISTICS ON, no stale stats. 2: AUTO_UPDATE_STATISTICS ON, some stale stats. 1: AUTO_UPDATE_STATISTICS OFF, no stale stats. 0: AUTO_UPDATE_STATISTICS OFF, stale stats.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @AutoUpdateStats BIT;
    SELECT @AutoUpdateStats = is_auto_update_stats_on FROM sys.databases WHERE name = DB_NAME();

    DECLARE @StaleStats NVARCHAR(MAX) = NULL;
    SELECT @StaleStats = STRING_AGG(QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name) + '':' + QUOTENAME(s.name), '', '')
    FROM sys.stats s
    JOIN sys.tables t ON s.object_id = t.object_id
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
    WHERE sp.modification_counter > 500
      AND (CAST(sp.modification_counter AS FLOAT) / NULLIF(sp.rows, 0) > 0.20 OR DATEDIFF(day, sp.last_updated, GETUTCDATE()) > 30);

    DECLARE @DbScore INT;
    IF @AutoUpdateStats = 1 AND @StaleStats IS NULL
        SET @DbScore = 3;
    ELSE IF @AutoUpdateStats = 1 AND @StaleStats IS NOT NULL
        SET @DbScore = 2;
    ELSE IF @AutoUpdateStats = 0 AND @StaleStats IS NULL
        SET @DbScore = 1;
    ELSE
        SET @DbScore = 0;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@pDbName, @DbScore, ISNULL(@StaleStats, ''No stale statistics found''));
    ';
    EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
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