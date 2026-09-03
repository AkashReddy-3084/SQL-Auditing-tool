-- Checklist: Deduplication verified - no duplicate business keys after load
-- Scope: DATABASE
-- Scoring: 3 = every evaluated table enforces uniqueness on a non-identity (business) key; 2 = under 5% without it; 1 = under 25% without it; 0 = 25%+ without it, or no user tables

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Business-key uniqueness could not be evaluated in the current database';
DECLARE @DwTotal INT = 0;
DECLARE @DwOk INT = 0;
DECLARE @AllTotal INT = 0;
DECLARE @AllOk INT = 0;
DECLARE @DwGaps NVARCHAR(MAX) = '';
DECLARE @AllGaps NVARCHAR(MAX) = '';
DECLARE @Probe INT = 1;

BEGIN TRY
    ;WITH scored AS (
        SELECT s.name AS sch, t.name AS tbl,
               CASE WHEN s.name IN ('dw','edw','mart','marts','dm','datamart','gold','presentation','star','analytics','reporting')
                         OR t.name LIKE 'dim%' OR t.name LIKE 'fact%' OR t.name LIKE '%mart%'
                    THEN 1 ELSE 0 END AS IsDw,
               CASE WHEN EXISTS (
                        SELECT 1
                        FROM sys.indexes AS i
                        WHERE i.object_id = t.object_id
                          AND i.is_unique = 1
                          AND i.is_disabled = 0
                          AND EXISTS (
                                SELECT 1
                                FROM sys.index_columns AS ic
                                JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                                WHERE ic.object_id = i.object_id
                                  AND ic.index_id = i.index_id
                                  AND ic.is_included_column = 0
                                  AND c.is_identity = 0))
                    THEN 1 ELSE 0 END AS HasUq
        FROM sys.tables AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
    )
    SELECT @AllTotal = COUNT(*),
           @AllOk = ISNULL(SUM(HasUq), 0),
           @DwTotal = ISNULL(SUM(IsDw), 0),
           @DwOk = ISNULL(SUM(CASE WHEN IsDw = 1 AND HasUq = 1 THEN 1 ELSE 0 END), 0),
           @AllGaps = ISNULL(LEFT(STRING_AGG(CASE WHEN HasUq = 0 THEN CONVERT(NVARCHAR(MAX), sch + '.' + tbl) END, ', '), 350), ''),
           @DwGaps = ISNULL(LEFT(STRING_AGG(CASE WHEN IsDw = 1 AND HasUq = 0 THEN CONVERT(NVARCHAR(MAX), sch + '.' + tbl) END, ', '), 350), '')
    FROM scored;
END TRY
BEGIN CATCH
    SET @Probe = 0;
    SET @Finding = 'Index metadata unavailable: ' + LEFT(ERROR_MESSAGE(), 200);
END CATCH;

DECLARE @Layer NVARCHAR(30) = CASE WHEN ISNULL(@DwTotal, 0) > 0 THEN 'dimension/fact table' ELSE 'user table' END;
DECLARE @Total INT = CASE WHEN ISNULL(@DwTotal, 0) > 0 THEN @DwTotal ELSE ISNULL(@AllTotal, 0) END;
DECLARE @Ok INT = CASE WHEN ISNULL(@DwTotal, 0) > 0 THEN ISNULL(@DwOk, 0) ELSE ISNULL(@AllOk, 0) END;
DECLARE @Gaps NVARCHAR(MAX) = CASE WHEN ISNULL(@DwTotal, 0) > 0 THEN ISNULL(@DwGaps, '') ELSE ISNULL(@AllGaps, '') END;
DECLARE @GapPct DECIMAL(9,2) = ISNULL(100.0 * (@Total - @Ok) / NULLIF(@Total, 0), 0);

IF @Probe = 1
BEGIN
    SET @Score = CASE
        WHEN @Total = 0 THEN 0
        WHEN @GapPct = 0 THEN 3
        WHEN @GapPct < 5 THEN 2
        WHEN @GapPct < 25 THEN 1
        ELSE 0 END;

    IF @Total = 0
        SET @Finding = 'No user tables found in ' + @DatabaseQueried + '; no business keys to deduplicate';
    ELSE
        SET @Finding = CONCAT(@DatabaseQueried, ': ', @Total - @Ok, ' of ', @Total, ' ', @Layer, '(s) (',
            CONVERT(NVARCHAR(10), @GapPct), '%) have no unique constraint or unique index on a non-identity key',
            CASE WHEN LEN(@Gaps) > 0 THEN ' - ' + @Gaps ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
