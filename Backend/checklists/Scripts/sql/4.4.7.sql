-- Checklist: Archival/purge process exists for aged data
-- Scope: SERVER
-- Scoring: 3 = purge modules, archive tables, purge jobs, and partition schemes are all evidenced; 2 = at least two evidence categories are present; 1 = one category is present; 0 = no evidence or a source is unavailable
-- NOTE: Automated evidence uses SQL text and object-name patterns; retention periods and process suitability require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Archival and purge evidence unavailable';
DECLARE @PurgeModuleCount INT = 0;
DECLARE @ArchiveTableCount INT = 0;
DECLARE @PurgeJobCount INT = 0;
DECLARE @PartitionSchemeCount INT = 0;
DECLARE @EvidenceCategoryCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @PurgeModuleCount = COUNT(*)
    FROM sys.sql_modules
    WHERE definition LIKE N'%DELETE%'
      AND (definition LIKE N'%archive%' OR definition LIKE N'%purge%' OR definition LIKE N'%retention%');

    SELECT @ArchiveTableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND (name LIKE N'%archive%' OR name LIKE N'%history%' OR name LIKE N'%[_]hist');

    SELECT @PurgeJobCount = COUNT(*)
    FROM msdb.dbo.sysjobsteps
    WHERE command LIKE N'%purge%'
       OR command LIKE N'%archive%'
       OR command LIKE N'%retention%';

    SELECT @PartitionSchemeCount = COUNT(*)
    FROM sys.partition_schemes;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @EvidenceCategoryCount =
    CASE WHEN @PurgeModuleCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @ArchiveTableCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @PurgeJobCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @PartitionSchemeCount > 0 THEN 1 ELSE 0 END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @EvidenceCategoryCount >= 4 THEN 3
    WHEN @EvidenceCategoryCount >= 2 THEN 2
    WHEN @EvidenceCategoryCount = 1 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'purge modules = ', @PurgeModuleCount,
    N'; archive/history tables = ', @ArchiveTableCount,
    N'; purge/retention jobs = ', @PurgeJobCount,
    N'; partition schemes = ', @PartitionSchemeCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more archival sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
