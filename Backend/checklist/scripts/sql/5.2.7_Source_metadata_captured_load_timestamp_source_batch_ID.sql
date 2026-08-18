-- Checklist: Source metadata captured (load timestamp, source, batch ID)
-- Scope: DATABASE
-- Scoring: 3 = All user tables contain all three metadata columns; 2 = >=75% compliant; 1 = >=25% compliant; 0 = <25% compliant.

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
    -- Azure SQL Database: Evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalTables INT;
    DECLARE @CompliantTables INT;
    DECLARE @MissingTables NVARCHAR(MAX);
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    WITH TableMetadata AS (
        SELECT
            t.object_id,
            s.name AS schema_name,
            t.name AS table_name,
            MAX(CASE WHEN c.name IN (''load_date'', ''load_timestamp'', ''etl_load_dt'', ''insert_dt'', ''created_dt'', ''load_dt'', ''ingestion_date'') THEN 1 ELSE 0 END) AS has_load_ts,
            MAX(CASE WHEN c.name IN (''source_system'', ''source'', ''src_sys'', ''source_name'', ''src'', ''source_db'') THEN 1 ELSE 0 END) AS has_source,
            MAX(CASE WHEN c.name IN (''batch_id'', ''batch_no'', ''load_batch'', ''batch_number'', ''batch_num'') THEN 1 ELSE 0 END) AS has_batch
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        LEFT JOIN sys.columns c ON c.object_id = t.object_id
        WHERE t.type = ''U'' AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
        GROUP BY t.object_id, s.name, t.name
    )
    SELECT @TotalTables = COUNT(*),
           @CompliantTables = SUM(CASE WHEN has_load_ts = 1 AND has_source = 1 AND has_batch = 1 THEN 1 ELSE 0 END),
           @MissingTables = STRING_AGG(CASE WHEN has_load_ts = 1 AND has_source = 1 AND has_batch = 1 THEN NULL ELSE schema_name + ''.'' + table_name END, '', '')
    FROM TableMetadata;

    IF @TotalTables = 0
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''No user tables found.'';
    END
    ELSE
    BEGIN
        DECLARE @Pct FLOAT = @CompliantTables * 100.0 / @TotalTables;
        IF @Pct >= 100 SET @DbScore = 3;
        ELSE IF @Pct >= 75 SET @DbScore = 2;
        ELSE IF @Pct >= 25 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        IF @DbScore = 3
            SET @DbFinding = ''All '' + CAST(@TotalTables AS NVARCHAR) + '' user tables contain required source metadata columns.'';
        ELSE
            SET @DbFinding = CAST(@CompliantTables AS NVARCHAR) + '' of '' + CAST(@TotalTables AS NVARCHAR) + '' user tables contain required source metadata columns. Missing: '' + ISNULL(@MissingTables, ''None'');
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
    ';
    EXEC(@Sql);
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
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
            DECLARE @TotalTables INT;
            DECLARE @CompliantTables INT;
            DECLARE @MissingTables NVARCHAR(MAX);
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            WITH TableMetadata AS (
                SELECT
                    t.object_id,
                    s.name AS schema_name,
                    t.name AS table_name,
                    MAX(CASE WHEN c.name IN (''load_date'', ''load_timestamp'', ''etl_load_dt'', ''insert_dt'', ''created_dt'', ''load_dt'', ''ingestion_date'') THEN 1 ELSE 0 END) AS has_load_ts,
                    MAX(CASE WHEN c.name IN (''source_system'', ''source'', ''src_sys'', ''source_name'', ''src'', ''source_db'') THEN 1 ELSE 0 END) AS