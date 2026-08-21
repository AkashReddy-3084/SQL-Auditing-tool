-- Checklist: SQL Agent / scheduler jobs inventoried and owned
-- Scope: SERVER
-- Scoring: 3: 100% jobs owned and described; 2: >=90% owned and >=80% described; 1: >=50% owned; 0: <50% owned.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @TotalJobs INT = 0;
DECLARE @OwnedJobs INT = 0;
DECLARE @DescribedJobs INT = 0;
DECLARE @UnownedJobs NVARCHAR(MAX);

IF @EngineEdition = 5 OR OBJECT_ID('msdb.dbo.sysjobs') IS NULL
BEGIN
    SET @Score = 3;
    SET @Finding = 'SQL Agent is not available on this platform. No jobs to evaluate.';
END
ELSE
BEGIN
    SELECT 
        @TotalJobs = COUNT(*),
        @OwnedJobs = SUM(CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE sid = j.owner_sid) THEN 1 ELSE 0 END),
        @DescribedJobs = SUM(CASE WHEN LEN(ISNULL(j.description, '')) > 0 THEN 1 ELSE 0 END)
    FROM msdb.dbo.sysjobs j;

    IF @TotalJobs = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No SQL Agent jobs found.';
    END
    ELSE
    BEGIN
        DECLARE @OwnedPct FLOAT = CAST(@OwnedJobs AS FLOAT) / @TotalJobs * 100;
        DECLARE @DescribedPct FLOAT = CAST(@DescribedJobs AS FLOAT) / @TotalJobs * 100;

        IF @OwnedPct = 100 AND @DescribedPct = 100
            SET @Score = 3;
        ELSE IF @OwnedPct >= 90 AND @DescribedPct >= 80
            SET @Score = 2;
        ELSE IF @OwnedPct >= 50
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        SET @Finding = CONCAT(
            'Total jobs: ', @TotalJobs, 
            '; Owned: ', @OwnedJobs, ' (', CAST(@OwnedPct AS INT), '%)',
            '; Described: ', @DescribedJobs, ' (', CAST(@DescribedPct AS INT), '%)'
        );

        IF @Score < 2
        BEGIN
            SELECT @UnownedJobs = STRING_AGG(name, ', ')
            FROM msdb.dbo.sysjobs
            WHERE NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE sid = owner_sid);
            
            IF @UnownedJobs IS NULL SET @UnownedJobs = 'None';
            SET @Finding = CONCAT(@Finding, '; Unowned jobs: ', @UnownedJobs);
        END
    END
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;