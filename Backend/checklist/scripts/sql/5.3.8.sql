-- Checklist: Freshness validation: marts updated within SLA
-- Scope: DATABASE
-- Scoring: 3 = 80%+ of mart tables carry a load/refresh timestamp plus a freshness artifact or a load inside the 24h SLA; 2 = 50%+ coverage or a freshness artifact; 1 = partial coverage or only a recent load; 0 = no mart tables or no freshness evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Mart freshness evidence could not be collected in the current database';
DECLARE @SlaHours INT = 24;
DECLARE @MartTables INT = 0;
DECLARE @WithTsCol INT = 0;
DECLARE @Artifacts INT = 0;
DECLARE @ArtifactList NVARCHAR(MAX) = '';
DECLARE @GapList NVARCHAR(MAX) = '';
DECLARE @LastLoad DATETIME2(3) = NULL;
DECLARE @Recent INT = 0;
DECLARE @Probe INT = 1;

BEGIN TRY
    ;WITH marts AS (
        SELECT t.object_id, s.name AS sch, t.name AS tbl
        FROM sys.tables AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
          AND (s.name IN ('mart','marts','dm','datamart','dw','edw','gold','presentation','rpt','bi','star','analytics','reporting')
               OR s.name LIKE '%mart%' OR t.name LIKE '%mart%'
               OR t.name LIKE 'dim%' OR t.name LIKE 'fact%' OR t.name LIKE 'agg[_]%')
    ), flagged AS (
        SELECT marts.sch, marts.tbl,
               CASE WHEN EXISTS (
                        SELECT 1
                        FROM sys.columns AS c
                        JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
                        WHERE c.object_id = marts.object_id
                          AND ty.name IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
                          AND (c.name LIKE '%load%' OR c.name LIKE '%refresh%' OR c.name LIKE '%etl%'
                               OR c.name LIKE '%modified%' OR c.name LIKE '%updated%' OR c.name LIKE '%process%'))
                    THEN 1 ELSE 0 END AS HasTs
        FROM marts
    )
    SELECT @MartTables = COUNT(*),
           @WithTsCol = ISNULL(SUM(HasTs), 0),
           @GapList = ISNULL(LEFT(STRING_AGG(CASE WHEN HasTs = 0 THEN CONVERT(NVARCHAR(MAX), sch + '.' + tbl) END, ', '), 300), '')
    FROM flagged;

    SELECT @Artifacts = COUNT(*),
           @ArtifactList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + '.' + o.name), ', '), 250), '')
    FROM sys.objects AS o
    JOIN sys.schemas AS s ON s.schema_id = o.schema_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('U','V','P','FN','IF','TF')
      AND (o.name LIKE '%freshness%' OR o.name LIKE '%stale%' OR o.name LIKE '%watermark%'
           OR o.name LIKE '%load[_]log%' OR o.name LIKE '%etl[_]log%' OR o.name LIKE '%load[_]audit%'
           OR o.name LIKE '%batch[_]control%' OR o.name LIKE '%last[_]refresh%' OR o.name LIKE '%sla%');
END TRY
BEGIN CATCH
    SET @Probe = 0;
    SET @Finding = 'Mart metadata unavailable: ' + LEFT(ERROR_MESSAGE(), 200);
END CATCH;

BEGIN TRY
    SELECT @LastLoad = MAX(CONVERT(DATETIME2(3), u.last_user_update))
    FROM sys.dm_db_index_usage_stats AS u
    JOIN sys.tables AS t ON t.object_id = u.object_id
    WHERE u.database_id = DB_ID() AND t.is_ms_shipped = 0;
END TRY
BEGIN CATCH
    SET @LastLoad = NULL;
END CATCH;

SET @MartTables = ISNULL(@MartTables, 0);
SET @WithTsCol = ISNULL(@WithTsCol, 0);
SET @Artifacts = ISNULL(@Artifacts, 0);
SET @Recent = CASE WHEN @LastLoad IS NOT NULL AND @LastLoad >= DATEADD(HOUR, -@SlaHours, SYSDATETIME()) THEN 1 ELSE 0 END;

DECLARE @CovPct DECIMAL(9,2) = ISNULL(100.0 * @WithTsCol / NULLIF(@MartTables, 0), 0);

IF @Probe = 1
BEGIN
    SET @Score = CASE
        WHEN @MartTables = 0 THEN 0
        WHEN @CovPct >= 80 AND (@Artifacts > 0 OR @Recent = 1) THEN 3
        WHEN @CovPct >= 50 OR @Artifacts > 0 THEN 2
        WHEN @CovPct > 0 OR @Recent = 1 THEN 1
        ELSE 0 END;

    IF @MartTables = 0
        SET @Finding = 'No mart/dimension/fact tables found in ' + @DatabaseQueried + '; no freshness SLA to verify';
    ELSE
        SET @Finding = CONCAT(@DatabaseQueried, ': ', @WithTsCol, ' of ', @MartTables, ' mart table(s) (',
            CONVERT(NVARCHAR(10), @CovPct), '%) expose a load/refresh timestamp column; last recorded write ',
            ISNULL(CONVERT(NVARCHAR(19), @LastLoad, 120), 'unknown'),
            ' (within ' + CONVERT(NVARCHAR(10), @SlaHours) + 'h SLA: ' + CASE WHEN @Recent = 1 THEN 'yes' ELSE 'no' END + '); ',
            @Artifacts, ' freshness/SLA monitoring object(s)',
            CASE WHEN LEN(@ArtifactList) > 0 THEN ' (' + @ArtifactList + ')' ELSE '' END,
            CASE WHEN LEN(@GapList) > 0 THEN '; untracked: ' + @GapList ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
