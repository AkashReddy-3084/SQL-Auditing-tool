-- Checklist: Statistics kept current (auto-update on, plus manual updates after large loads)
-- Scope: DATABASE
-- Scoring: 3 = auto-update is ON and no statistic on a table of 1000+ rows is older than 30 days; 2 = auto-update is ON and under 5% are stale; 1 = auto-update is OFF, or under 25% are stale; 0 = 25% or more are stale, or the statistics metadata could not be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Statistics currency could not be evaluated in this database';
DECLARE @AutoUpdate INT = ISNULL(CONVERT(INT, DATABASEPROPERTYEX(DB_NAME(), 'IsAutoUpdateStatistics')), 0);
DECLARE @AutoCreate INT = ISNULL(CONVERT(INT, DATABASEPROPERTYEX(DB_NAME(), 'IsAutoCreateStatistics')), 0);
DECLARE @AutoAsync INT = ISNULL(CONVERT(INT, DATABASEPROPERTYEX(DB_NAME(), 'IsAutoUpdateStatisticsAsync')), 0);
DECLARE @Total INT = 0;
DECLARE @Stale INT = 0;
DECLARE @NeverRefreshed INT = 0;
DECLARE @OldestDays INT = 0;
DECLARE @Pct DECIMAL(9, 2) = 0;
DECLARE @Names NVARCHAR(MAX) = '';
DECLARE @Read BIT = 0;

DECLARE @S TABLE (
    TableName NVARCHAR(300) NOT NULL,
    IsStale INT NOT NULL,
    IsNever INT NOT NULL,
    AgeDays INT NOT NULL);

BEGIN TRY
    INSERT INTO @S (TableName, IsStale, IsNever, AgeDays)
    SELECT CONCAT(SCHEMA_NAME(o.schema_id), '.', o.name),
           CASE WHEN sp.last_updated IS NULL
                  OR sp.last_updated < DATEADD(DAY, -30, SYSDATETIME()) THEN 1 ELSE 0 END,
           CASE WHEN sp.last_updated IS NULL THEN 1 ELSE 0 END,
           ISNULL(DATEDIFF(DAY, sp.last_updated, SYSDATETIME()), 9999)
    FROM sys.stats AS s
    JOIN sys.objects AS o ON o.object_id = s.object_id
    OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE o.is_ms_shipped = 0
      AND o.type = 'U'
      AND ISNULL(sp.[rows], 0) >= 1000;

    SET @Read = 1;
END TRY
BEGIN CATCH
    SET @Read = 0;
END CATCH;

SELECT @Total = COUNT(*),
       @Stale = ISNULL(SUM(IsStale), 0),
       @NeverRefreshed = ISNULL(SUM(IsNever), 0),
       @OldestDays = ISNULL(MAX(CASE WHEN AgeDays < 9999 THEN AgeDays ELSE 0 END), 0)
FROM @S;

SELECT @Names = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), TableName), ', '), 400), 'none')
FROM @S
WHERE IsStale = 1;

SET @Pct = ISNULL(CONVERT(DECIMAL(9, 2), 100.0 * @Stale / NULLIF(@Total, 0)), 0);

SET @Score = CASE
    WHEN @Read = 0 THEN 0
    WHEN @AutoUpdate = 0 THEN 1
    WHEN @Stale = 0 THEN 3
    WHEN @Pct < 5 THEN 2
    WHEN @Pct < 25 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @Read = 0
        THEN 'sys.stats and sys.dm_db_stats_properties could not be read; statistics currency is unknown'
    ELSE CONCAT(
        'AUTO_UPDATE_STATISTICS = ', CASE WHEN @AutoUpdate = 1 THEN 'ON' ELSE 'OFF' END,
        '; AUTO_CREATE_STATISTICS = ', CASE WHEN @AutoCreate = 1 THEN 'ON' ELSE 'OFF' END,
        '; AUTO_UPDATE_STATISTICS_ASYNC = ', CASE WHEN @AutoAsync = 1 THEN 'ON' ELSE 'OFF' END,
        '; statistics on tables of 1000+ rows = ', @Total,
        '; last refreshed more than 30 days ago = ', @Stale, ' (', @Pct, '%)',
        '; never refreshed = ', @NeverRefreshed,
        '; oldest refresh age = ', @OldestDays, ' days',
        '; affected tables: ', @Names)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
