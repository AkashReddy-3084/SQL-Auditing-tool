DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

INSERT INTO #DbResults (DbName, DbScore)
SELECT name,
       CASE 
           WHEN snapshot_isolation_state = 1 THEN 3 
           WHEN is_read_committed_snapshot_on = 1 THEN 2 
           WHEN snapshot_isolation_state = 2 THEN 1 
           ELSE 0 
       END
FROM sys.databases
WHERE database_id > 4 AND state = 0;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;