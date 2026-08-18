-- Checklist: Customer-managed keys (CMK/BYOK) used where policy requires
-- Scope: DATABASE
-- Scoring: 0: No encryption or encryption disabled. 1: Encrypted with default/service-managed keys. 2: Encrypted with certificate/symmetric key (CMK proxy). 3: Explicit CMK/BYOK verified (caps at 2 due to policy dependency).
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @DbScore INT = 0;
        DECLARE @DbFinding NVARCHAR(MAX) = ''No encryption found'';

        IF EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID() AND encryption_state = 3 AND encryptor_type IN (''Certificate'', ''Symmetric Key''))
        BEGIN
            SET @DbScore = 2;
            SET @DbFinding = ''Encrypted with Certificate/Symmetric Key (CMK proxy)'';
        END
        ELSE IF EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID() AND encryption_state = 3)
        BEGIN
            SET @DbScore = 1;
            SET @DbFinding = ''Encrypted with default/service-managed key'';
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
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
                DECLARE @DbScore INT = 0;
                DECLARE @DbFinding NVARCHAR(MAX) = ''No encryption found'';

                IF EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID() AND encryption_state = 3 AND encryptor_type IN (''Certificate'', ''Symmetric Key''))
                BEGIN
                    SET @DbScore = 2;
                    SET @DbFinding = ''Encrypted with Certificate/Symmetric Key (CMK proxy)'';
                END
                ELSE IF EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID() AND encryption_state = 3)
                BEGIN
                    SET @DbScore = 1;
                    SET @DbFinding = ''Encrypted with default/service-managed key'';
                END

                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
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
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
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