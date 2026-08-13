-- Checklist: Lock escalation understood and mitigated where problematic
-- Scope: DATABASE
-- Scoring: 3=Disabled at DB level; 2=Enabled but zero current lock waits; 1=Enabled with 1-5 current lock waits; 0=Enabled with >5 current lock waits
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @IsEscEnabled INT;
        DECLARE @CurrentLockWaits INT;
        DECLARE @DbScore INT = 3;

        SELECT @IsEscEnabled = is_lock_escalation_enabled FROM sys.databases WHERE database_id = DB_ID();
        SELECT @CurrentLockWaits = COUNT(*) FROM sys.dm_exec_requests WHERE wait_type LIKE ''LCK_M%'' AND database_id = DB_ID() AND session_id <> @@SPID;

        IF @IsEscEnabled = 1
        BEGIN
            IF @CurrentLockWaits > 5 SET @DbScore = 0;
            ELSE IF @CurrentLockWaits > 0 SET @DbScore = 1;
            ELSE SET @DbScore = 2;
        END

        SELECT DB_NAME() AS DbName, @DbScore AS DbScore;';

        INSERT INTO #DbResults (DbName, DbScore)
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;