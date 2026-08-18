SET NOCOUNT ON;

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
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
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '';
    DECLARE @c3 INT = 0;

    SELECT @c3 = COUNT(*) FROM sys.tables t
    JOIN sys.columns c ON t.object_id = c.object_id
    WHERE (t.name LIKE '%reconcil%' OR t.name LIKE '%control%')
      AND (c.name LIKE '%count%' OR c.name LIKE '%status%' OR c.name LIKE '%batch%' OR c.name LIKE '%source%' OR c.name LIKE '%target%');

    IF @c3 > 0
    BEGIN
        SET @DbScore = 3;
        SELECT @DbFinding = ISNULL(STRING_AGG(t.name + '.' + c.name, ', '), 'None') FROM sys.tables t
        JOIN sys.columns c ON t.object_id = c.object_id
        WHERE (t.name LIKE '%reconcil%' OR t.name LIKE '%control%')
          AND (c.name LIKE '%count%' OR c.name LIKE '%status%' OR c.name LIKE '%batch%' OR c.name LIKE '%source%' OR c.name LIKE '%target%');
    END
    ELSE
    BEGIN
        DECLARE @c2 INT = 0;
        SELECT @c2 = COUNT(*) FROM sys.tables t WHERE t.name LIKE '%reconcil%' OR t.name LIKE '%control%';
        IF @c2 > 0
        BEGIN
            SET @DbScore = 2;
            SELECT @DbFinding = ISNULL(STRING_AGG(t.name, ', '), 'None') FROM sys.tables t WHERE t.name LIKE '%reconcil%' OR t.name LIKE '%control%';
        END
        ELSE
        BEGIN
            DECLARE @c1 INT = 0;
            SELECT @c1 = COUNT(*) FROM sys.tables t WHERE t.name LIKE '%log%' OR t.name LIKE '%hist%' OR t.name LIKE '%etl%';
            IF @c1 > 0
            BEGIN
                SET @DbScore = 1;
                SELECT @DbFinding = ISNULL(STRING_AGG(t.name, ', '), 'None') FROM sys.tables t WHERE t.name LIKE '%log%' OR t.name LIKE '%hist%' OR t.name LIKE '%etl%';
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = 'No reconciliation or ETL logging tables found';
            END
        END
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (DB_NAME(), @DbScore, @DbFinding);
    SET @DatabaseQueried = DB_NAME();
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
    DECLARE @DbName NVARCHAR(256);
    DECLARE @Sql NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @s INT = 0;
            DECLARE @f NVARCHAR(MAX) = '''';
            DECLARE @c3 INT = 0;
            SELECT @c3 = COUNT(*) FROM sys.tables t JOIN sys.columns c ON t.object_id = c.object_id
            WHERE (t.name LIKE ''%reconcil%'' OR t.name LIKE ''%control%'')
              AND (c.name LIKE ''%count%'' OR c.name LIKE ''%status%'' OR c.name LIKE ''%batch%'' OR c.name LIKE ''%source%'' OR c.name LIKE ''%target%'');
            IF @c3 > 0 BEGIN
                SET @s = 3;
                SELECT @f = ISNULL(STRING_AGG(t.name + ''.'' + c.name, '', ''), ''None'') FROM sys.tables t JOIN sys.columns c ON t.object_id = c.object_id
                WHERE (t.name LIKE ''%reconcil%'' OR t.name LIKE ''%control%'')
                  AND (c.name LIKE ''%count%'' OR c.name LIKE ''%status%'' OR c.name LIKE ''%batch%'' OR c.name LIKE ''%source%'' OR c.name LIKE ''%target%'');
            END ELSE BEGIN
                DECLARE @c2 INT = 0;
                SELECT @c2 = COUNT(*) FROM sys.tables t WHERE t.name LIKE ''%reconcil%'' OR t.name LIKE ''%control%'';
                IF @c2 > 0 BEGIN
                    SET @s = 2;
                    SELECT @f = ISNULL(STRING_AGG(t.name, '', ''), ''None'') FROM sys.tables t WHERE t.name LIKE ''%reconcil%'' OR t.name LIKE ''%control%'';
                END ELSE BEGIN
                    DECLARE @c1 INT = 0;
                    SELECT @c1 = COUNT(*) FROM sys.tables t WHERE t.name LIKE ''%log%'' OR t.name LIKE ''%hist%'' OR t.name LIKE ''%etl%'';
                    IF @c1 > 0 BEGIN
                        SET @s = 1;
                        SELECT @f = ISNULL(STRING_AGG(t.name, '', ''), ''None'') FROM sys.tables t WHERE t.name LIKE ''%log%'' OR t.name LIKE ''%hist%'' OR t.name LIKE ''%etl%'';
                    END ELSE BEGIN
                        SET @s = 0;
                        SET @f = ''No reconciliation or ETL logging tables found'';
                    END
                END
            END
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@pDbName, @s, @f);';
            EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
END

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL(
    (SELECT STRING_AGG(DbName + ':