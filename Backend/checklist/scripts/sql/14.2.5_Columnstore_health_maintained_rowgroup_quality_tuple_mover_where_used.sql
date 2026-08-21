-- Checklist: Columnstore health maintained (rowgroup quality, tuple mover) where used
-- Scope: DATABASE
-- Scoring: 3: No columnstore indexes, or all rowgroups healthy (COMPRESSED/CLOSED). 2: Minor gaps (<10% open rowgroups). 1: Partial health (10-50% open). 0: Severe degradation (>50% open) or evaluation failed.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
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

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    EXEC sp_executesql N'
        DECLARE @TotalCount INT, @OpenCount INT, @DbScore INT, @Finding NVARCHAR(MAX);
        SELECT @TotalCount = COUNT(*), @OpenCount = SUM(CASE WHEN state = 0 THEN 1 ELSE 0 END)
        FROM sys.dm_db_column_store_row_group_physical_stats r
        JOIN sys.indexes i ON r.object_id = i.object_id AND r.index_id = i.index_id
        WHERE i.type_desc LIKE ''%COLUMNSTORE%'';

        IF @TotalCount = 0
        BEGIN
            SET @DbScore = 3;
            SET @Finding = ''No columnstore indexes found'';
        END
        ELSE
        BEGIN
            DECLARE @OpenPct FLOAT = CAST(@OpenCount AS FLOAT) / @TotalCount;
            IF @OpenCount = 0
            BEGIN
                SET @DbScore = 3;
                SET @Finding = ''All columnstore rowgroups are healthy (COMPRESSED/CLOSED)'';
            END
            ELSE
            BEGIN
                SELECT @Finding = STRING_AGG(OBJECT_SCHEMA_NAME(object_id) + ''.'' + OBJECT_NAME(object_id), '', '')
                FROM (SELECT DISTINCT object_id FROM sys.dm_db_column_store_row_group_physical_stats r 
                      JOIN sys.indexes i ON r.object_id = i.object_id AND r.index_id = i.index_id 
                      WHERE i.type_desc LIKE ''%COLUMNSTORE%'' AND r.state = 0) t;
                      
                IF @OpenPct < 0.10
                BEGIN
                    SET @DbScore = 2;
                    SET @Finding = ''Minor gaps: '' + CAST(@OpenCount AS NVARCHAR) + '' open rowgroups in: '' + @Finding;
                END
                ELSE IF @OpenPct < 0.50
                BEGIN
                    SET @DbScore = 1;
                    SET @Finding = ''Partial health: '' + CAST(@OpenCount AS NVARCHAR) + '' open rowgroups in: '' + @Finding;
                END
                ELSE
                BEGIN
                    SET @DbScore = 0;
                    SET @Finding = ''Severe degradation: '' + CAST(@OpenCount AS NVARCHAR) + '' open rowgroups in: '' + @Finding;
                END
            END
        END
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore, @Finding);
    ';
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
            DECLARE @TotalCount INT, @OpenCount INT, @DbScore INT, @Finding NVARCHAR(MAX);
            SELECT @TotalCount = COUNT(*), @OpenCount = SUM(CASE WHEN state = 0 THEN 1 ELSE 0 END)
            FROM sys.dm_db_column_store_row_group_physical_stats r
            JOIN sys.indexes i ON r.object_id = i.object_id AND r.index_id = i.index_id
            WHERE i.type_desc LIKE ''%COLUMNSTORE%'';

            IF @TotalCount = 0
            BEGIN
                SET @DbScore = 3;
                SET @Finding = ''No columnstore indexes found'';
            END
            ELSE
            BEGIN
                DECLARE @OpenPct FLOAT = CAST(@OpenCount AS FLOAT) / @TotalCount;
                IF @OpenCount = 0
                BEGIN
                    SET @DbScore = 3;
                    SET @Finding = ''All columnstore rowgroups are healthy (COMPRESSED/CLOSED)'';
                END