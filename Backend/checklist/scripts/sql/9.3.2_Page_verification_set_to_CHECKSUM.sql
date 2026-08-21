-- Checklist: Page verification set to CHECKSUM
-- Scope: DATABASE
-- Scoring: 0 = None set to CHECKSUM; 1 = <50% set to CHECKSUM; 2 = >=50% set to CHECKSUM; 3 = All user databases set to CHECKSUM

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @TotalDbs INT = 0;
DECLARE @ChecksumDbs INT = 0;
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @TotalDbs = 1;
    BEGIN TRY
        SET @Sql = N'DECLARE @PvDesc NVARCHAR(60) = (SELECT page_verify_option_desc FROM sys.databases WHERE database_id = DB_ID());
        DECLARE @DbScore INT = CASE WHEN @PvDesc = ''CHECKSUM'' THEN 3 ELSE 0 END;
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + @DbName + ''', @DbScore, ''page_verify_option = '' + @PvDesc);';
        EXEC sp_executesql @Sql;
        IF EXISTS (SELECT 1 FROM #DbResults WHERE DbName = @DbName AND DbScore = 3)
            SET @ChecksumDbs = 1;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate all online user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @TotalDbs += 1;
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @PvDesc NVARCHAR(60) = (SELECT page_verify_option_desc FROM sys.databases WHERE database_id = DB_ID());
            DECLARE @DbScore INT = CASE WHEN @PvDesc = ''CHECKSUM'' THEN 3 ELSE 0 END;
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, ''page_verify_option = '' + @PvDesc);
            ';
            EXEC sp_executesql @Sql;
            IF EXISTS (SELECT 1 FROM #DbResults WHERE DbName = @DbName AND DbScore = 3)
                SET @ChecksumDbs += 1;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName,