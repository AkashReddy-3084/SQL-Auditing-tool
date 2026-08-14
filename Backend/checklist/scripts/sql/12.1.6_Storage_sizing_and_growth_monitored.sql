DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

-- Check for active monitoring jobs (SQL Agent)
DECLARE @ActiveJobCount INT = 0;
SELECT @ActiveJobCount = COUNT(*) FROM msdb.dbo.sysjobs j
WHERE j.enabled = 1
  AND (LOWER(j.name) LIKE '%storage%' OR LOWER(j.name) LIKE '%space%' OR LOWER(j.name) LIKE '%disk%' OR LOWER(j.name) LIKE '%capacity%' OR LOWER(j.name) LIKE '%growth%');

IF @ActiveJobCount > 0 SET @Score = 2;

-- Check for disabled jobs (partial evidence)
IF @Score = 0
BEGIN
    DECLARE @DisabledJobCount INT = 0;
    SELECT @DisabledJobCount = COUNT(*) FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 0
      AND (LOWER(j.name) LIKE '%storage%' OR LOWER(j.name) LIKE '%space%' OR LOWER(j.name) LIKE '%disk%' OR LOWER(j.name) LIKE '%capacity%' OR LOWER(j.name) LIKE '%growth%');
    IF @DisabledJobCount > 0 SET @Score = 1;
END

-- Check for healthy file usage / auto-growth to bump to 3
IF @Score >= 2
BEGIN
    DECLARE @HealthyFiles INT = 0;
    DECLARE @TotalFiles INT = 0;
    
    -- Query master.sys.master_files directly and filter to user databases only
    SELECT @TotalFiles = COUNT(*) FROM master.sys.master_files WHERE type IN (0, 1) AND database_id > 4;
    
    SELECT @HealthyFiles = COUNT(*) FROM master.sys.master_files
    WHERE type IN (0, 1) AND database_id > 4
      AND (
        -- Auto growth is configured (not 0 or unlimited without max)
        (max_size > 0 AND max_size <> -1) OR growth > 0
      )
      AND (
        -- Current size is less than 80% of max size, or max_size is unlimited (-1)
        (max_size = -1) OR (CAST(size AS FLOAT) / NULLIF(max_size, 0) < 0.8)
      );

    IF @TotalFiles > 0 AND (@HealthyFiles * 100.0 / @TotalFiles) >= 70.0
        SET @Score = 3;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;