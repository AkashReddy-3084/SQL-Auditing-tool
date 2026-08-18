-- Checklist: Appropriate isolation level / RCSI or snapshot isolation considered
-- Scope: DATABASE
-- Scoring: 3: RCSI enabled. 2: Snapshot Isolation enabled. 1: Neither enabled, but DB is single-user. 0: Neither enabled, multi-user read-write.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

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
        IF @EngineEdition = 5
        BEGIN
            -- Azure SQL Database: RCSI is always ON by default and cannot be changed.
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 3, 'Azure SQL Database: RCSI is always enabled by default.');
        END
        ELSE
        BEGIN
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @RCSI INT = (SELECT is_read_committed_snapshot_on FROM sys.databases WHERE database_id = DB_ID());
            DECLARE @Snapshot INT = (SELECT snapshot_isolation_state FROM sys.databases WHERE database_id = DB_ID());
            DECLARE @UserAccess INT = (SELECT user_access FROM sys.databases WHERE database_id = DB_ID());
            
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);
            
            IF @RCSI = 1
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''RCSI enabled'';
            END
            ELSE IF @Snapshot = 1
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''Snapshot Isolation enabled'';
            END
            ELSE IF @UserAccess = 2
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = ''Neither enabled; DB is single-user'';
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''Neither enabled; multi-user read-write'';
            END
            
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, @DbFinding);';

            EXEC sp_executesql @Sql;
        END
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @DatabaseQueried = ISNULL(
    (SELECT STRING_AGG(DbName, ', ') FROM #DbResults),
    'None'
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;