-- Checklist: Key metrics tracked (CPU, memory, IO, DTU/vCore, waits)
-- Scope: SERVER
-- Scoring: 3 = all categories present; 2 = 3 categories present; 1 = 1-2 categories present; 0 = no metrics found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No metrics found';

DECLARE @CPU_Count INT = 0;
DECLARE @Mem_Count INT = 0;
DECLARE @IO_Count INT = 0;
DECLARE @Wait_Count INT = 0;

-- Check CPU metrics
SELECT @CPU_Count = COUNT(*) 
FROM sys.dm_os_performance_counters 
WHERE object_name LIKE '%Processor%' OR object_name LIKE '%CPU%';

-- Check Memory metrics
SELECT @Mem_Count = COUNT(*) 
FROM sys.dm_os_performance_counters 
WHERE object_name LIKE '%Memory%' OR object_name LIKE '%Buffer Manager%';

-- Check IO metrics
SELECT @IO_Count = COUNT(*) 
FROM sys.dm_os_performance_counters 
WHERE object_name LIKE '%Physical Disk%' OR object_name LIKE '%IO%';

-- Check Wait stats
SELECT @Wait_Count = COUNT(*) 
FROM sys.dm_os_wait_stats;

DECLARE @Total_Categories INT = 0;
IF @CPU_Count > 0 SET @Total_Categories = @Total_Categories + 1;
IF @Mem_Count > 0 SET @Total_Categories = @Total_Categories + 1;
IF @IO_Count > 0 SET @Total_Categories = @Total_Categories + 1;
IF @Wait_Count > 0 SET @Total_Categories = @Total_Categories + 1;

SET @Finding = 'CPU: ' + CAST(CASE WHEN @CPU_Count > 0 THEN 'Yes' ELSE 'No' END AS NVARCHAR(10)) + 
               ', Mem: ' + CAST(CASE WHEN @Mem_Count > 0 THEN 'Yes' ELSE 'No' END AS NVARCHAR(10)) + 
               ', IO: ' + CAST(CASE WHEN @IO_Count > 0 THEN 'Yes' ELSE 'No' END AS NVARCHAR(10)) + 
               ', Waits: ' + CAST(CASE WHEN @Wait_Count > 0 THEN 'Yes' ELSE 'No' END AS NVARCHAR(10));

SET @Score = CASE 
    WHEN @Total_Categories = 4 THEN 3 
    WHEN @Total_Categories = 3 THEN 2 
    WHEN @Total_Categories >= 1 THEN 1 
    ELSE 0 
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;