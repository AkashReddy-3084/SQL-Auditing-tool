-- Checklist: Appropriate isolation levels used (no unnecessary SERIALIZABLE; RCSI considered)
-- Scope: DATABASE
-- Scoring: 3=RCSI ON & 0 SERIALIZABLE; 2=RCSI ON & >0 SERIALIZABLE OR RCSI OFF & 0 SERIALIZABLE; 1=RCSI OFF & 1-5 SERIALIZABLE; 0=RCSI OFF & >5 SERIALIZABLE
SET NOCOUNT ON;
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
DECLARE @RCSI INT = (SELECT is_read_committed_snapshot_on FROM sys.databases WHERE name = DB_NAME());
DECLARE @SerCount INT = (SELECT COUNT(*) FROM sys.sql_modules WHERE definition LIKE ''%SERIALIZABLE%'');
DECLARE @DbScore INT;
IF @RCSI = 1 AND @SerCount = 0 SET @DbScore = 3;
ELSE IF @RCSI = 1 AND @SerCount > 0 SET @DbScore = 2;
ELSE IF @RCSI = 0 AND @SerCount = 0 SET @DbScore = 2;
ELSE IF @RCSI = 0 AND @SerCount BETWEEN 1 AND 5 SET @DbScore = 1;
ELSE SET @DbScore = 0;
INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore);
';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script checks stored procedures, functions, triggers, and views. Ad-hoc queries require SQL Audit to verify.