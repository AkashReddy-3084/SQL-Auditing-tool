-- Checklist: Transparent Data Encryption (TDE) enabled for encryption at rest
-- Scope: DATABASE
-- Scoring: 3=All DBs encrypted, 2=Majority encrypted, 1=Some encrypted, 0=None encrypted

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: TDE is always enabled by platform design
    SET @Score = 3;
    SET @DatabaseQueried = DB_NAME();
    SET @Finding = 'TDE is always enabled in Azure SQL Database.';
END
ELSE
BEGIN
    -- SQL Server / Azure SQL Managed Instance
    DECLARE @DbName NVARCHAR(256);
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE @EncryptedCount INT = 0;
    DECLARE @TotalCount INT = 0;

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
        SET @TotalCount = @TotalCount + 1;
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @EncState INT;
            SELECT @EncState = encryption_state FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID();
            IF ISNULL(@EncState, 1) = 3
            BEGIN
                INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 3, ''TDE enabled'');
            END
            ELSE
            BEGIN
                INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, ''TDE not enabled'');
            END';
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

    SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);

    SELECT @EncryptedCount = COUNT(*) FROM #DbResults WHERE DbScore = 3;

    IF @TotalCount = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No user databases found.';
    END
    ELSE
    BEGIN
        DECLARE @Pct FLOAT = CAST(@EncryptedCount AS FLOAT) / @TotalCount * 100;
        IF @Pct = 100 SET @Score = 3;
        ELSE IF @Pct >= 50 SET @Score = 2;
        ELSE IF @Pct > 0 SET @Score = 1;
        ELSE SET @Score = 0;

        SET @Finding = ISNULL(
            (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
            'No non-compliant findings found'
        );
    END

    DROP TABLE #DbResults;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;