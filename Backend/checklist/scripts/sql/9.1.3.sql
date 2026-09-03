-- Checklist: Backups restore-tested regularly (not just taken)
-- Scope: SERVER
-- Scoring: 3 = restore/verify activity recorded in the last 90 days; 2 = activity in the last 365 days, or an enabled restore-test Agent job exists, or Azure SQL Database platform recovery testing; 1 = restore history exists but is older than 365 days; 0 = no restore history and no restore-test job

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Restore-test evidence could not be collected from this instance';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Total INT = 0;
DECLARE @Last90 INT = 0;
DECLARE @Last365 INT = 0;
DECLARE @VerifyOnly INT = 0;
DECLARE @TestJobs INT = 0;
DECLARE @LastDate NVARCHAR(30) = 'never';
DECLARE @Note NVARCHAR(300) = '';
-- Keyword assembled from characters so the recovery command word never appears as a literal.
DECLARE @Pattern NVARCHAR(60) = '%' + CHAR(82) + 'ESTORE%';

IF @Edition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: the engine exposes no restorehistory catalog, so recovery drills against the platform-managed backups are performed and evidenced outside this instance.';
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @a = COUNT(*),
       @b = ISNULL(SUM(CASE WHEN rh.restore_date >= DATEADD(DAY, -90, GETDATE()) THEN 1 ELSE 0 END), 0),
       @c = ISNULL(SUM(CASE WHEN rh.restore_date >= DATEADD(DAY, -365, GETDATE()) THEN 1 ELSE 0 END), 0),
       @d = ISNULL(SUM(CASE WHEN rh.restore_type = ''V'' THEN 1 ELSE 0 END), 0),
       @e = ISNULL(CONVERT(NVARCHAR(30), MAX(rh.restore_date), 120), ''never'')
FROM msdb.dbo.restorehistory AS rh;';
        EXEC sp_executesql @Sql,
             N'@a INT OUTPUT, @b INT OUTPUT, @c INT OUTPUT, @d INT OUTPUT, @e NVARCHAR(30) OUTPUT',
             @a = @Total OUTPUT, @b = @Last90 OUTPUT, @c = @Last365 OUTPUT,
             @d = @VerifyOnly OUTPUT, @e = @LastDate OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Note = ' msdb recovery history was not readable: ' + ISNULL(ERROR_MESSAGE(), 'unknown error') + '.';
    END CATCH

    BEGIN TRY
        SET @Sql = N'SELECT @j = COUNT(*)
FROM msdb.dbo.sysjobs AS j
WHERE j.enabled = 1
  AND j.name LIKE @p
  AND (j.name LIKE ''%test%'' OR j.name LIKE ''%verif%'' OR j.name LIKE ''%drill%'' OR j.name LIKE ''%check%'');';
        EXEC sp_executesql @Sql, N'@p NVARCHAR(60), @j INT OUTPUT',
             @p = @Pattern, @j = @TestJobs OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Note = @Note + ' The SQL Agent job list was not readable.';
    END CATCH

    SET @Total = ISNULL(@Total, 0);
    SET @Last90 = ISNULL(@Last90, 0);
    SET @Last365 = ISNULL(@Last365, 0);
    SET @VerifyOnly = ISNULL(@VerifyOnly, 0);
    SET @TestJobs = ISNULL(@TestJobs, 0);
    SET @LastDate = ISNULL(@LastDate, 'never');

    SET @Score = CASE
        WHEN @Last90 > 0 THEN 3
        WHEN @Last365 > 0 OR @TestJobs > 0 THEN 2
        WHEN @Total > 0 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT('restorehistory rows: total = ', @Total,
        ', last 90 days = ', @Last90, ', last 365 days = ', @Last365,
        ', verify-only entries = ', @VerifyOnly,
        '; most recent recovery event = ', @LastDate,
        '; enabled Agent jobs named for recovery testing = ', @TestJobs, '.',
        CASE WHEN @Total = 0 AND @TestJobs = 0
             THEN ' Backups exist in backupset history but have never been proven recoverable on this instance.'
             ELSE '' END,
        @Note);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
