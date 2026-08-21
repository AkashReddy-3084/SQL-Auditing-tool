-- Checklist: Star schema implemented (fact + dimension tables, not flat wide tables)
-- Scope: DATABASE
-- Scoring: 3 = Fact and Dim tables found; 2 = Mixed/Partial star; 1 = Only flat wide tables found; 0 = No tables found or error.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT DB_NAME(),
           CASE 
             WHEN (SELECT COUNT(*) FROM sys.foreign_keys) > 0 AND (SELECT COUNT(*) FROM sys.tables) > 1 THEN 3 
             WHEN (SELECT COUNT(*) FROM sys.foreign_keys) > 0 THEN 2
             WHEN (SELECT COUNT(*) FROM sys.tables) > 0 THEN 1 
             ELSE 0 
           END,
           CASE 
             WHEN (SELECT COUNT(*) FROM sys.foreign_keys) > 0 AND (SELECT COUNT(*) FROM sys.tables) > 1 THEN 'Star schema evidence found (FKs and multiple tables present)'
             WHEN (SELECT COUNT(*) FROM sys.foreign_keys) > 0 THEN 'Partial star schema evidence (FKs present but low table count)'
             WHEN (SELECT COUNT(*) FROM sys.tables) > 0 THEN 'Flat tables only (no FKs found)'
             ELSE 'No tables found'
           END;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT @p_Db,
                CASE 
                  WHEN (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys) > 0 AND (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables) > 1 THEN 3 
                  WHEN (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys) > 0 THEN 2
                  WHEN (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables) > 0 THEN 1 
                  ELSE 0 
                END,
                CASE 
                  WHEN (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys) > 0 AND (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables) > 1 THEN ''Star schema evidence found (FKs and multiple tables present)''
                  WHEN (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys) > 0 THEN ''Partial star schema evidence (FKs present but low table count)''
                  WHEN (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables) > 0 THEN ''Flat tables only (no FKs found)''
                  ELSE ''No tables found''
                END';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Evaluation failed: ' + ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

IF NOT EXISTS (SELECT 1 FROM #DbResults)
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
    SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
    SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;