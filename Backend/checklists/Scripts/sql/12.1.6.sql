SET NOCOUNT ON;

DECLARE @CriticalCount int = 0;
DECLARE @WarningCount int = 0;
DECLARE @DatabaseCount int = 0;
DECLARE @FileCount int = 0;
DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @Finding nvarchar(max);

;WITH FileStorage AS
(
    SELECT
        d.name AS DatabaseName,
        mf.file_id,
        mf.type_desc,
        mf.size,
        mf.max_size,
        mf.growth,
        mf.is_percent_growth,
        vs.volume_mount_point,
        vs.total_bytes,
        vs.available_bytes
    FROM sys.master_files AS mf
    INNER JOIN sys.databases AS d
        ON d.database_id = mf.database_id
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
    WHERE d.state_desc = N'ONLINE'
      AND d.source_database_id IS NULL
), Assessment AS
(
    SELECT
        DatabaseName,
        file_id,
        CASE
            WHEN growth = 0 THEN 1
            WHEN total_bytes > 0
             AND (100.0 * CONVERT(decimal(19,4), available_bytes) / CONVERT(decimal(19,4), total_bytes)) < 10.0 THEN 1
            ELSE 0
        END AS IsCritical,
        CASE
            WHEN growth > 0 AND is_percent_growth = 1 THEN 1
            WHEN growth > 0 AND is_percent_growth = 0 AND growth < 8192 THEN 1
            WHEN total_bytes > 0
             AND (100.0 * CONVERT(decimal(19,4), available_bytes) / CONVERT(decimal(19,4), total_bytes)) >= 10.0
             AND (100.0 * CONVERT(decimal(19,4), available_bytes) / CONVERT(decimal(19,4), total_bytes)) < 20.0 THEN 1
            ELSE 0
        END AS IsWarning
    FROM FileStorage
)
SELECT
    @CriticalCount = COALESCE(SUM(IsCritical), 0),
    @WarningCount = COALESCE(SUM(CASE WHEN IsCritical = 0 THEN IsWarning ELSE 0 END), 0),
    @FileCount = COUNT(*),
    @DatabaseCount = COUNT(DISTINCT DatabaseName)
FROM Assessment;

SET @Finding =
    N'Assessed ' + CONVERT(nvarchar(20), @FileCount) + N' files across '
    + CONVERT(nvarchar(20), @DatabaseCount) + N' online databases. Critical findings: '
    + CONVERT(nvarchar(20), @CriticalCount) + N'; warning findings: '
    + CONVERT(nvarchar(20), @WarningCount)
    + N'. Critical criteria are disabled autogrowth or volume free space below 10%; warning criteria are percentage growth, fixed growth below 64 MB, or volume free space from 10% to below 20%.';

SET @Result = CASE
    WHEN @FileCount = 0 OR @CriticalCount > 0 THEN N'Fail'
    WHEN @WarningCount > 0 THEN N'Partial'
    ELSE N'Pass'
END;

SET @Score = CASE
    WHEN @FileCount = 0 OR @CriticalCount > 0 THEN 1
    WHEN @WarningCount > 0 THEN 2
    ELSE 3
END;

SELECT
    @Result AS Result,
    @Score AS Score,
    N'SERVER' AS DatabaseQueried,
    CASE WHEN @FileCount = 0 THEN N'No online database file evidence was returned.' ELSE @Finding END AS Finding;