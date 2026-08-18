-- Checklist: Temporal tables / change tracking used for data history where required
-- Scope: DATABASE
-- Scoring: 0: No tables with temporal or change tracking found. 1: 1-2 tables found. 2: 3-9 tables found. 3: 10 or more tables found.

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

DECLARE @TempTables TABLE (TableName NVARCHAR(256), FeatureType NVARCHAR(20));

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    SELECT 
        QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) AS TableName,
        CASE WHEN t.temporal_type > 0 THEN ''Temporal'' ELSE ''ChangeTracking'' END AS FeatureType
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    LEFT JOIN sys.change_tracking_tables ct ON t.object_id = ct.object_id
    WHERE t.temporal_type > 0 OR ct.object_id IS NOT NULL;
    ';
    
    INSERT INTO @TempTables EXEC sp_executesql @Sql;
    
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '';
    
    SELECT @DbScore = CASE 
        WHEN COUNT(*) = 0 THEN 0
        WHEN COUNT(*) BETWEEN 1 AND 2 THEN 1
        WHEN COUNT(*) BETWEEN 3 AND 9 THEN 2
        ELSE 3
    END,
    @DbFinding = STRING_AGG(TableName + '' ('' + FeatureType + '')'', '', '')
    FROM @TempTables;
    
    IF @DbFinding IS NULL OR @DbFinding = '' SET @DbFinding = ''No tables with temporal or change tracking found'';
    
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @DbFinding);
    SET @DatabaseQueried = @DbName;
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
            SELECT 
                QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) AS TableName,
                CASE WHEN t.temporal_type > 0 THEN ''Temporal'' ELSE ''ChangeTracking'' END AS FeatureType
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            LEFT JOIN sys.change_tracking_tables ct ON t.object_id = ct.object_id
            WHERE t.temporal_type > 0 OR ct.object_id IS NOT NULL;
            ';
            
            DELETE FROM @TempTables;
            INSERT INTO @TempTables EXEC sp_executesql @Sql;
            
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = '';
            
            SELECT @DbScore = CASE 
                WHEN COUNT(*) = 0 THEN 0
                WHEN COUNT(*) BETWEEN 1 AND 2 THEN 1
                WHEN COUNT(*) BETWEEN 3 AND 9 THEN 2
                ELSE 3
            END,
            @DbFinding = STRING_AGG(TableName + '' ('' + FeatureType + '')'', '', '')
            FROM @TempTables;
            
            IF @DbFinding IS NULL OR @DbFinding = '' SET @DbFinding = ''No tables with temporal or change tracking found'';
            
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @DbFinding);
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, ''Database evaluation failed'');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    SET @DatabaseQueried = (
        SELECT STRING_AGG(DbName, '', '')
        FROM #DbResults
    );
END

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + '': '' + Finding, ''; '')
        FROM #DbResults
        WHERE Finding IS NOT NULL AND Finding <> ''
    ),
    ''No non-compliant findings found''
);

SET @Result = CASE WHEN @Score >= 2 THEN ''Pass'' ELSE ''Fail'' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;