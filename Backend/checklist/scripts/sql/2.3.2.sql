-- Checklist: Failed loads are restartable from point of failure (not full re-run)
-- Scope: DATABASE
-- Scoring: 3 = restart state tables exist and at least one procedure reads them; 2 = restart state tables exist but no module reads them; 1 = ETL modules exist with no restart state at all; 0 = no ETL modules and no restart state tables in this database

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Load restartability evidence was unavailable in this database';
DECLARE @Ctl INT = 0;
DECLARE @Readers INT = 0;
DECLARE @CtlList NVARCHAR(MAX) = '';
DECLARE @EtlProcs INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @Ctl = COUNT(*),
           @Readers = ISNULL(SUM(c.IsRead), 0),
           @CtlList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), c.FullName), ', '), 300), '')
    FROM
    (
        SELECT s.name + '.' + t.name AS FullName,
               CASE WHEN EXISTS (SELECT 1
                                 FROM sys.sql_expression_dependencies AS d
                                 INNER JOIN sys.objects AS o ON o.object_id = d.referencing_id
                                 WHERE d.referenced_id = t.object_id
                                   AND o.type IN ('P', 'FN', 'IF', 'TF')) THEN 1 ELSE 0 END AS IsRead
        FROM sys.tables AS t
        INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
          AND (t.name LIKE '%watermark%' OR t.name LIKE '%checkpoint%' OR t.name LIKE '%control%'
               OR t.name LIKE '%batch%' OR t.name LIKE '%[_]log' OR t.name LIKE '%loadlog%'
               OR t.name LIKE '%runlog%' OR t.name LIKE '%load%status%' OR t.name LIKE '%etl%log%')
          AND EXISTS (SELECT 1
                      FROM sys.columns AS col
                      WHERE col.object_id = t.object_id
                        AND (col.name LIKE '%status%' OR col.name LIKE '%state%'
                             OR col.name LIKE '%watermark%' OR col.name LIKE '%checkpoint%'
                             OR col.name LIKE '%batch%' OR col.name LIKE '%last[_]%'
                             OR col.name LIKE '%processed%' OR col.name LIKE '%high[_]water%'
                             OR col.name LIKE '%end[_]time%'))
    ) AS c;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH

BEGIN TRY
    SELECT @EtlProcs = COUNT(*)
    FROM sys.procedures AS pr
    WHERE pr.is_ms_shipped = 0
      AND (pr.name LIKE '%etl%' OR pr.name LIKE '%load%' OR pr.name LIKE '%stag%'
           OR pr.name LIKE '%import%' OR pr.name LIKE '%ingest%' OR pr.name LIKE '%refresh%');
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH

SET @Score = CASE WHEN @Ctl > 0 AND @Readers > 0 THEN 3
                  WHEN @Ctl > 0 THEN 2
                  WHEN @EtlProcs > 0 THEN 1
                  ELSE 0 END;

SET @Finding = CASE
    WHEN @ReadError = 1 AND @Ctl = 0 AND @EtlProcs = 0
        THEN 'Table, column and dependency catalog metadata in this database could not be read'
    WHEN @Ctl = 0 AND @EtlProcs = 0
        THEN 'No batch, watermark, checkpoint or load-log tables carrying restart state exist in this database, and no ETL-named procedures were found'
    WHEN @Ctl = 0
        THEN CONCAT('ETL-named procedures = ', @EtlProcs,
                    ' but no batch, watermark, checkpoint or load-log table carrying restart state exists, so a failed load has no recorded resume point')
    ELSE CONCAT('Restart state tables = ', @Ctl, ' (', @CtlList, ')',
                '; of those, referenced by a procedure or function = ', @Readers,
                '; ETL-named procedures = ', @EtlProcs)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
