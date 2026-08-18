-- Checklist: Memory grants monitored (no excessive spills to tempdb)
-- Scope: SERVER
-- Scoring: 3=0 spills/sec, 2=1-10 spills/sec or metric unavailable (partial), 1=11-100, 0=>100
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @SpillRate BIGINT;
DECLARE @Sql NVARCHAR(MAX);

SET @SpillRate = -1;

IF OBJECT_ID('sys.dm_os_performance_counters') IS NOT NULL
BEGIN
    SET @Sql = N'SELECT @SpillRate = ISNULL(CAST(MAX(cntr_value) AS BIGINT), 0)
    FROM sys.dm_os_performance_counters
    WHERE object_name = ''SQLServer:Memory Manager''
      AND counter_name = ''Spills to tempdb/sec'';';
    EXEC sp_executesql @Sql, N'@SpillRate BIGINT OUTPUT', @SpillRate OUTPUT;
END

SET @Score = CASE
    WHEN @SpillRate = -1 THEN 2
    WHEN @SpillRate = 0 THEN 3
    WHEN @SpillRate BETWEEN 1 AND 10 THEN 2
    WHEN @SpillRate BETWEEN 11 AND 100 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @SpillRate = -1 THEN 'Spills to tempdb/sec counter unavailable on this platform. Partial evidence only; manual review recommended.'
    ELSE 'Spills to tempdb/sec: ' + CAST(@SpillRate AS NVARCHAR(20))
END;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;