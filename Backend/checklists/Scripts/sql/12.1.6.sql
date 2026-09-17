-- Checklist: Storage sizing and growth monitored
-- Scope: DATABASE
-- Scoring: 3 = no file flagged; 2 = 1 file flagged; 1 = 2 files flagged; 0 = 3 or more flagged, or no files readable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Storage sizing and growth evidence could not be read for the current database';
DECLARE @Files INT = 0;
DECLARE @Flagged INT = 0;
DECLARE @Bad NVARCHAR(MAX) = '';
DECLARE @AllocMB DECIMAL(19,2) = 0;
DECLARE @DataUsedPct DECIMAL(9,2) = 0;

BEGIN TRY
    ;WITH f AS
    (
        SELECT df.name AS FileName,
               df.type_desc AS FileType,
               df.growth AS Growth,
               df.is_percent_growth AS PctGrowth,
               CONVERT(DECIMAL(19,4), df.max_size) AS MaxPages,
               CONVERT(DECIMAL(19,4), df.size) AS AllocPages,
               CONVERT(DECIMAL(19,4), ISNULL(FILEPROPERTY(df.name, 'SpaceUsed'), 0)) AS UsedPages
        FROM sys.database_files AS df
        WHERE df.type_desc IN ('ROWS', 'LOG')
    ),
    a AS
    (
        SELECT FileName,
               FileType,
               AllocPages,
               UsedPages,
               CASE
                   WHEN Growth = 0 THEN 'autogrowth disabled'
                   WHEN PctGrowth = 1 THEN 'percentage autogrowth'
                   WHEN Growth < 8192 THEN 'fixed autogrowth below 64 MB'
                   WHEN MaxPages > 0 AND AllocPages > MaxPages * 0.9 THEN 'within 10 percent of max size'
                   WHEN FileType = 'ROWS' AND AllocPages > 0 AND UsedPages > AllocPages * 0.9 THEN 'over 90 percent full'
                   ELSE NULL
               END AS Issue
        FROM f
    )
    SELECT @Files = COUNT(*),
           @Flagged = ISNULL(SUM(CASE WHEN Issue IS NOT NULL THEN 1 ELSE 0 END), 0),
           @AllocMB = ISNULL(CONVERT(DECIMAL(19,2), SUM(AllocPages) * 8.0 / 1024.0), 0),
           @DataUsedPct = ISNULL(CONVERT(DECIMAL(9,2), 100.0
                              * SUM(CASE WHEN FileType = 'ROWS' THEN UsedPages ELSE 0 END)
                              / NULLIF(SUM(CASE WHEN FileType = 'ROWS' THEN AllocPages ELSE 0 END), 0)), 0),
           @Bad = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX),
                      CASE WHEN Issue IS NOT NULL THEN FileName + ' (' + Issue + ')' END), ', '), 500), '')
    FROM a;
END TRY
BEGIN CATCH
    SET @Files = 0;
    SET @Flagged = 0;
END CATCH;

SET @Score = CASE
                WHEN @Files = 0 THEN 0
                WHEN @Flagged = 0 THEN 3
                WHEN @Flagged = 1 THEN 2
                WHEN @Flagged = 2 THEN 1
                ELSE 0
             END;

SET @Finding = CASE
    WHEN @Files = 0
        THEN 'No data or log files could be read from sys.database_files for this database'
    WHEN @Flagged = 0
        THEN CONCAT(@Files, ' file(s), ', @AllocMB, ' MB allocated, data files ', @DataUsedPct,
                    ' percent used; every file uses bounded fixed-MB autogrowth with headroom')
    ELSE CONCAT(@Flagged, ' of ', @Files, ' file(s) flagged; ', @AllocMB, ' MB allocated, data files ',
                @DataUsedPct, ' percent used; ', @Bad)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;