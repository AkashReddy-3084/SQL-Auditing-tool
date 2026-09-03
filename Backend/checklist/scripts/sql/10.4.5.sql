-- Checklist: Log/rowcount reconciliation captured per ETL run
-- Scope: DATABASE
-- Scoring: 3 = a run-log table carries run/batch id, row counts and a timestamp and holds logged runs; 2 = such a table exists but holds no rows; 1 = only partial row-count logging columns found; 0 = no ETL run/rowcount log table found

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'ETL run/rowcount logging evidence could not be collected in this database';

DECLARE @Logs TABLE
(
    FullName   NVARCHAR(300) NOT NULL,
    HasRunId   INT           NOT NULL,
    HasTime    INT           NOT NULL,
    LoggedRows BIGINT        NOT NULL
);

DECLARE @Any INT = 0;
DECLARE @Complete INT = 0;
DECLARE @Runs BIGINT = 0;
DECLARE @List NVARCHAR(MAX) = '';

BEGIN TRY
    INSERT INTO @Logs (FullName, HasRunId, HasTime, LoggedRows)
    SELECT s.name + '.' + t.name,
           MAX(CASE WHEN c.name LIKE '%run[_]id%' OR c.name LIKE '%runid%'
                      OR c.name LIKE '%batch[_]id%' OR c.name LIKE '%batchid%'
                      OR c.name LIKE '%load[_]id%' OR c.name LIKE '%loadid%'
                      OR c.name LIKE '%execution[_]id%' OR c.name LIKE '%executionid%'
                    THEN 1 ELSE 0 END),
           MAX(CASE WHEN c.name LIKE '%date%' OR c.name LIKE '%time%' OR c.name LIKE '%stamp%'
                    THEN 1 ELSE 0 END),
           ISNULL(MIN(rc.RowCnt), 0)
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    INNER JOIN sys.columns AS c ON c.object_id = t.object_id
    OUTER APPLY (SELECT SUM(ps.row_count) AS RowCnt
                 FROM sys.dm_db_partition_stats AS ps
                 WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)) AS rc
    WHERE t.is_ms_shipped = 0
      AND (t.name LIKE '%etl%' OR t.name LIKE '%log%' OR t.name LIKE '%audit%'
           OR t.name LIKE '%batch%' OR t.name LIKE '%load%' OR t.name LIKE '%run%'
           OR t.name LIKE '%recon%' OR t.name LIKE '%process%'
           OR s.name LIKE '%etl%' OR s.name LIKE '%audit%' OR s.name LIKE '%log%')
    GROUP BY s.name, t.name
    HAVING MAX(CASE WHEN c.name LIKE '%rowcount%' OR c.name LIKE '%row[_]count%'
                      OR c.name LIKE '%rowcnt%' OR c.name LIKE '%rows[_]%'
                      OR c.name LIKE '%[_]rows%' OR c.name LIKE '%recordcount%'
                      OR c.name LIKE '%reconcil%'
                    THEN 1 ELSE 0 END) = 1;
END TRY
BEGIN CATCH
    SET @Score = 0;
END CATCH

SELECT @Any = COUNT(*),
       @Complete = ISNULL(SUM(CASE WHEN HasRunId = 1 AND HasTime = 1 THEN 1 ELSE 0 END), 0),
       @Runs = ISNULL(SUM(CASE WHEN HasRunId = 1 AND HasTime = 1 THEN LoggedRows ELSE 0 END), 0)
FROM @Logs;

SET @List = ISNULL((SELECT LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), FullName), ', '), 400) FROM @Logs), '');

SET @Score = CASE WHEN @Complete > 0 AND @Runs > 0 THEN 3
                  WHEN @Complete > 0 THEN 2
                  WHEN @Any > 0 THEN 1
                  ELSE 0 END;

SET @Finding = CASE
    WHEN @Any = 0
        THEN 'No user table combines ETL/log/batch/run naming with a row-count column, so no per-run rowcount reconciliation log exists in this database'
    ELSE CONCAT(@Any, ' row-count logging table(s) found (', @List, '); ', @Complete,
                ' of them also carry a run/batch id and a timestamp column and currently hold ',
                @Runs, ' logged run row(s)')
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
