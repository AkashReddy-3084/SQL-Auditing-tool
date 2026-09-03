SET NOCOUNT ON;

DECLARE @DatabaseQueried NVARCHAR(256) = N'SERVER: ' + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128));
DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(4000);

DECLARE @DbStats TABLE (
    DatabaseName        SYSNAME NOT NULL,
    AutoCreateStats     BIT     NOT NULL,
    AutoCreateStatsInc  BIT     NOT NULL,
    AutoUpdateStats     BIT     NOT NULL
);

INSERT INTO @DbStats (DatabaseName, AutoCreateStats, AutoCreateStatsInc, AutoUpdateStats)
SELECT d.name,
       d.is_auto_create_stats_on,
       d.is_auto_create_stats_incremental_on,
       d.is_auto_update_stats_on
FROM sys.databases AS d
WHERE d.state_desc = N'ONLINE'
  AND d.is_read_only = 0
  AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb', N'distribution',
                     N'SSISDB', N'ReportServer', N'ReportServerTempDB');

DECLARE @TotalDbs INT;
DECLARE @EnabledDbs INT;
DECLARE @IncrementalDbs INT;
DECLARE @AutoUpdateOffDbs INT;

SELECT @TotalDbs          = COUNT(*),
       @EnabledDbs        = SUM(CASE WHEN AutoCreateStats = 1 THEN 1 ELSE 0 END),
       @IncrementalDbs    = SUM(CASE WHEN AutoCreateStatsInc = 1 THEN 1 ELSE 0 END),
       @AutoUpdateOffDbs  = SUM(CASE WHEN AutoUpdateStats = 0 THEN 1 ELSE 0 END)
FROM @DbStats;

SET @TotalDbs         = ISNULL(@TotalDbs, 0);
SET @EnabledDbs       = ISNULL(@EnabledDbs, 0);
SET @IncrementalDbs   = ISNULL(@IncrementalDbs, 0);
SET @AutoUpdateOffDbs = ISNULL(@AutoUpdateOffDbs, 0);

DECLARE @DisabledList NVARCHAR(2000);

SELECT @DisabledList = STUFF((
        SELECT N', ' + s.DatabaseName
        FROM @DbStats AS s
        WHERE s.AutoCreateStats = 0
        ORDER BY s.DatabaseName
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(2000)'), 1, 2, N'');

SET @DisabledList = ISNULL(@DisabledList, N'(none)');

DECLARE @EnabledPct INT = CASE WHEN @TotalDbs = 0 THEN 0 ELSE (@EnabledDbs * 100) / @TotalDbs END;

IF @TotalDbs = 0
    SET @Score = 0;
ELSE IF @EnabledDbs = @TotalDbs
    SET @Score = 3;
ELSE IF @EnabledPct >= 90
    SET @Score = 2;
ELSE IF @EnabledPct >= 50
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF @TotalDbs = 0
    SET @Finding = N'No ONLINE, writable, non-system databases were found on this instance, so AUTO_CREATE_STATISTICS could not be assessed for any user database.';
ELSE IF @EnabledDbs = @TotalDbs
    SET @Finding = N'AUTO_CREATE_STATISTICS is ENABLED on all ' + CAST(@TotalDbs AS NVARCHAR(10))
                 + N' user database(s). Incremental auto-create statistics is on for '
                 + CAST(@IncrementalDbs AS NVARCHAR(10)) + N' of them, and '
                 + CAST(@AutoUpdateOffDbs AS NVARCHAR(10))
                 + N' database(s) have AUTO_UPDATE_STATISTICS disabled.';
ELSE
    SET @Finding = N'AUTO_CREATE_STATISTICS is ENABLED on only ' + CAST(@EnabledDbs AS NVARCHAR(10))
                 + N' of ' + CAST(@TotalDbs AS NVARCHAR(10)) + N' user database(s) ('
                 + CAST(@EnabledPct AS NVARCHAR(10)) + N'%). Database(s) with AUTO_CREATE_STATISTICS OFF: '
                 + @DisabledList + N'. Additionally ' + CAST(@AutoUpdateOffDbs AS NVARCHAR(10))
                 + N' database(s) have AUTO_UPDATE_STATISTICS disabled.';

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;