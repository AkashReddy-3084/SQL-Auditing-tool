-- Checklist: Filegroups used to organize storage where applicable (SQL Server/MI)
-- Scope: DATABASE
-- Scoring: 3 = >1 filegroup; 2 = 1 filegroup; 1 = 0 filegroups; 0 = database not readable

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    -- Azure SQL Database typically has a single managed filegroup
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT DB_NAME(),
           2,
           'Azure SQL Database: Platform managed storage (single filegroup equivalent)';
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
                    WHEN COUNT(*) > 1 THEN 3 
                    WHEN COUNT(*) = 1 THEN 2 
                    ELSE 1 
                END,
                CASE 
                    WHEN COUNT(*) > 1 THEN ''Multiple filegroups found: '' + CAST(COUNT(*) AS VARCHAR(10))
                    WHEN COUNT(*) = 1 THEN ''Single filegroup used''
                    ELSE ''No filegroups found''
                END
                FROM ' + QUOTENAME(@DbName) + N'.sys.filegroups;';

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

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;