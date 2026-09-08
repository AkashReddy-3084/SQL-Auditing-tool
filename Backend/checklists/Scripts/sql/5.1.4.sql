-- Checklist: [DQ Framework & Governance] DQ results logged and trended over time
-- Scope: DATABASE
-- Scoring: 3 = a DQ result/log table has a timestamp column and 100 or more retained rows; 2 = a DQ result/log table has a timestamp column and at least 1 row; 1 = DQ result/log tables exist but are empty or lack a timestamp column; 0 = no DQ result or log table found

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Data quality result logging could not be inspected in the current database';

DECLARE @Candidates INT = -1;
DECLARE @Timestamped INT = 0;
DECLARE @Populated INT = 0;
DECLARE @MaxRows BIGINT = 0;
DECLARE @CandidateList NVARCHAR(MAX) = 'none';

DECLARE @Log TABLE
(
    ObjectId INT PRIMARY KEY,
    FullName NVARCHAR(300),
    TimeColumn NVARCHAR(128) NULL,
    RowCnt BIGINT
);

BEGIN TRY
    INSERT INTO @Log (ObjectId, FullName, TimeColumn, RowCnt)
    SELECT t.object_id,
           CONVERT(NVARCHAR(300), s.name + '.' + t.name),
           (SELECT TOP (1) CONVERT(NVARCHAR(128), c.name)
            FROM sys.columns AS c
            INNER JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
            WHERE c.object_id = t.object_id
              AND ty.name IN ('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
            ORDER BY CASE WHEN c.name LIKE '%run%' THEN 1
                          WHEN c.name LIKE '%exec%' THEN 2
                          WHEN c.name LIKE '%load%' THEN 3
                          WHEN c.name LIKE '%check%' THEN 4
                          WHEN c.name LIKE '%created%' THEN 5
                          ELSE 6 END, c.column_id),
           ISNULL((SELECT SUM(ps.row_count) FROM sys.dm_db_partition_stats AS ps
                   WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)), 0)
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND (t.name LIKE '%data[_]quality%' OR t.name LIKE '%dataquality%'
           OR t.name LIKE 'dq[_]%' OR t.name LIKE '%[_]dq[_]%' OR t.name LIKE '%[_]dq'
           OR t.name LIKE '%quality%result%' OR t.name LIKE '%quality%log%'
           OR t.name LIKE '%quality%score%' OR t.name LIKE '%quality%history%'
           OR t.name LIKE '%validation%result%' OR t.name LIKE '%validation%log%'
           OR t.name LIKE '%rule%result%' OR t.name LIKE '%rule%violation%'
           OR t.name LIKE '%profil%result%' OR t.name LIKE '%reconcil%'
           OR t.name LIKE '%exception%log%' OR t.name LIKE '%anomaly%');

    SELECT @Candidates  = COUNT(*),
           @Timestamped = ISNULL(SUM(CASE WHEN TimeColumn IS NOT NULL THEN 1 ELSE 0 END), 0),
           @Populated   = ISNULL(SUM(CASE WHEN TimeColumn IS NOT NULL AND RowCnt > 0 THEN 1 ELSE 0 END), 0),
           @MaxRows     = ISNULL(MAX(CASE WHEN TimeColumn IS NOT NULL THEN RowCnt ELSE 0 END), 0)
    FROM @Log;

    SET @CandidateList = ISNULL(LEFT((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX),
                                          FullName + ' [ts=' + ISNULL(TimeColumn, 'none')
                                          + ', rows=' + CONVERT(NVARCHAR(20), RowCnt) + ']'), ', ')
                                      FROM @Log), 800), 'none');
END TRY
BEGIN CATCH
    SET @Candidates = -1;
END CATCH;

SET @Score = CASE
    WHEN @Candidates < 0 THEN 0
    WHEN @Candidates = 0 THEN 0
    WHEN @Populated > 0 AND @MaxRows >= 100 THEN 3
    WHEN @Populated > 0 THEN 2
    ELSE 1
END;

SET @Finding = CASE
    WHEN @Candidates < 0
        THEN CONCAT('Catalog views in ', @DatabaseQueried, ' could not be read, so DQ result logging was not inspected.')
    WHEN @Candidates = 0
        THEN CONCAT('No data-quality result, validation, rule-violation or reconciliation log tables were found in ',
                    @DatabaseQueried, '; DQ outcomes are not persisted, so they cannot be trended.')
    WHEN @Populated = 0
        THEN CONCAT(@Candidates, ' candidate DQ result/log table(s) found in ', @DatabaseQueried,
                    ', of which ', @Timestamped, ' carry a date/time column, but none holds any rows: ', @CandidateList, '.')
    ELSE CONCAT(@Populated, ' of ', @Candidates, ' DQ result/log table(s) in ', @DatabaseQueried,
                ' carry a date/time column and retained history, the largest holding ', @MaxRows,
                ' row(s): ', @CandidateList, '.')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
