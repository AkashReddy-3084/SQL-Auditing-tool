-- Checklist: Dependencies documented (linked servers, cross-database references)
-- Scope: DATABASE
-- Scoring: 3: All dependencies documented or none exist. 2: >=80% documented. 1: >=20% documented. 0: <20% documented or evaluation failed.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @LinkedServerFinding NVARCHAR(MAX) = 'No linked servers found';
DECLARE @LinkedServerScore INT = 3;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

-- Check linked servers (server-level)
SELECT @LinkedServerFinding = ISNULL(STRING_AGG(name, ', '), 'No linked servers found'),
       @LinkedServerScore = CASE WHEN COUNT(*) = 0 THEN 3
                                 WHEN SUM(CASE WHEN EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = s.server_id AND ep.class = 100) THEN 1 ELSE 0 END) * 100.0 / COUNT(*) >= 80 THEN 2
                                 WHEN SUM(CASE WHEN EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = s.server_id AND ep.class = 100) THEN 1 ELSE 0 END) * 100.0 / COUNT(*) >= 20 THEN 1
                                 ELSE 0 END
FROM sys.servers s
WHERE is_linked = 1;

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DatabaseQueried = DB_NAME();
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT DB_NAME(),
           CASE WHEN COUNT(*) = 0 THEN 3
                WHEN SUM(CASE WHEN ep.major_id IS NOT NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(*) >= 80 THEN 2
                WHEN SUM(CASE WHEN ep.major_id IS NOT NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(*) >= 20 THEN 1
                ELSE 0 END,
           ISNULL(STRING_AGG(CASE WHEN ep.major_id IS NULL THEN OBJECT_NAME(dep.referencing_id) ELSE NULL END, ', '), 'No cross-database references found')
    FROM sys.sql_expression_dependencies dep
    LEFT JOIN sys.extended_properties ep ON ep.major_id = dep.referencing_id AND ep.class = 1
    WHERE dep.referenced_database_name IS NOT NULL
      AND dep.referenced_database_name <> DB_NAME();
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
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT ''' + @DbName + ''',
                   CASE WHEN COUNT(*) = 0 THEN 3
                        WHEN SUM(CASE WHEN ep.major_id IS NOT NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(*) >= 80 THEN 2
                        WHEN SUM(CASE WHEN ep.major_id IS NOT NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(*) >= 20 THEN 1
                        ELSE 0 END,
                   ISNULL(STRING_AGG(CASE WHEN ep.major_id IS NULL THEN OBJECT_NAME(dep.referencing_id) ELSE NULL END, '',''), ''''No cross-database references found''''')
            FROM sys.sql_expression_dependencies dep
            LEFT JOIN sys.extended_properties ep ON ep.major_id = dep.referencing_id AND ep.class = 1
            WHERE dep.referenced_database_name IS NOT NULL
              AND dep.referenced_database_name <> DB_NAME();
            ';
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

    SET @DatabaseQueried = (
        SELECT STRING