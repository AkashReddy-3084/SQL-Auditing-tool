SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(4000);
DECLARE @DatabaseQueried NVARCHAR(128) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128));

IF @DatabaseQueried IS NULL
    SET @DatabaseQueried = DB_NAME();

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = N'Azure SQL Database detected (EngineEdition 5). Page verification is permanently set to CHECKSUM by the platform, is not configurable and cannot be disabled, so torn/corrupt page detection is always active.';
END
ELSE
BEGIN
    DECLARE @DbList TABLE
    (
        DatabaseName SYSNAME NOT NULL,
        PageVerify NVARCHAR(60) NOT NULL,
        StateDesc NVARCHAR(60) NOT NULL
    );

    INSERT INTO @DbList (DatabaseName, PageVerify, StateDesc)
    SELECT d.name,
           ISNULL(NULLIF(LTRIM(RTRIM(d.page_verify_option_desc)), N''), N'UNKNOWN'),
           ISNULL(d.state_desc, N'UNKNOWN')
    FROM sys.databases AS d
    WHERE d.database_id <> 2
      AND d.source_database_id IS NULL;

    DECLARE @Total INT = 0;
    DECLARE @ChecksumCount INT = 0;
    DECLARE @NonChecksumCount INT = 0;
    DECLARE @BadList NVARCHAR(2000);

    SELECT @Total = COUNT(*),
           @ChecksumCount = SUM(CASE WHEN PageVerify = N'CHECKSUM' THEN 1 ELSE 0 END)
    FROM @DbList;

    SET @Total = ISNULL(@Total, 0);
    SET @ChecksumCount = ISNULL(@ChecksumCount, 0);
    SET @NonChecksumCount = @Total - @ChecksumCount;

    SELECT @BadList = STUFF((
        SELECT N', ' + b.DatabaseName + N' [' + b.PageVerify + N'/' + b.StateDesc + N']'
        FROM @DbList AS b
        WHERE b.PageVerify <> N'CHECKSUM'
        ORDER BY b.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    SET @BadList = LEFT(ISNULL(@BadList, N'none'), 1500);

    IF @Total = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No databases were visible in sys.databases (tempdb and database snapshots are excluded by design). Page verification could not be confirmed for any database; the audit login may lack VIEW ANY DATABASE permission.';
    END
    ELSE IF @NonChecksumCount = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All ' + CAST(@Total AS NVARCHAR(10)) + N' evaluated database(s) have PAGE_VERIFY set to CHECKSUM (tempdb and database snapshots excluded). Torn and corrupt page detection is enabled server-wide.';
    END
    ELSE IF @ChecksumCount = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'None of the ' + CAST(@Total AS NVARCHAR(10)) + N' evaluated database(s) use CHECKSUM page verification. Non-compliant databases [setting/state]: ' + @BadList;
    END
    ELSE IF @ChecksumCount > @NonChecksumCount
    BEGIN
        SET @Score = 2;
        SET @Finding = CAST(@ChecksumCount AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10)) + N' evaluated database(s) use CHECKSUM page verification; ' + CAST(@NonChecksumCount AS NVARCHAR(10)) + N' do not. Non-compliant databases [setting/state]: ' + @BadList;
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Only ' + CAST(@ChecksumCount AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10)) + N' evaluated database(s) use CHECKSUM page verification; ' + CAST(@NonChecksumCount AS NVARCHAR(10)) + N' do not. Non-compliant databases [setting/state]: ' + @BadList;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;