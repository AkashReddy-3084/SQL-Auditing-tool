-- Checklist: Source metadata captured (load timestamp, source, batch ID)
-- Scope: DATABASE
-- Scoring: 3 = 80%+ of user tables carry load timestamp, source and batch id; 2 = 50%+ carry all three or 80%+ carry at least one; 1 = some table carries at least one; 0 = none, or no user tables

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Source metadata columns could not be evaluated in the current database';
DECLARE @Total INT = 0;
DECLARE @All3 INT = 0;
DECLARE @Any INT = 0;
DECLARE @BareList NVARCHAR(MAX) = '';
DECLARE @Probe INT = 1;

BEGIN TRY
    ;WITH flagged AS (
        SELECT s.name AS sch, t.name AS tbl,
               MAX(CASE WHEN ty.name IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
                         AND (c.name LIKE '%load%date%' OR c.name LIKE '%load%time%' OR c.name LIKE '%load[_]ts%'
                              OR c.name LIKE '%loaddate%' OR c.name LIKE '%etl%date%' OR c.name LIKE '%insert%date%'
                              OR c.name LIKE '%ingest%' OR c.name LIKE '%processed%' OR c.name LIKE '%created%')
                        THEN 1 ELSE 0 END) AS HasLoadTs,
               MAX(CASE WHEN c.name LIKE '%source%' OR c.name LIKE '%src[_]%' OR c.name LIKE '%[_]src'
                              OR c.name LIKE '%origin%' OR c.name LIKE '%system[_]of[_]record%'
                        THEN 1 ELSE 0 END) AS HasSource,
               MAX(CASE WHEN c.name LIKE '%batch%' OR c.name LIKE '%run[_]id%' OR c.name LIKE '%runid%'
                              OR c.name LIKE '%load[_]id%' OR c.name LIKE '%loadid%'
                              OR c.name LIKE '%execution[_]id%' OR c.name LIKE '%package[_]id%'
                        THEN 1 ELSE 0 END) AS HasBatch
        FROM sys.tables AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        JOIN sys.columns AS c ON c.object_id = t.object_id
        JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
        WHERE t.is_ms_shipped = 0
        GROUP BY s.name, t.name
    )
    SELECT @Total = COUNT(*),
           @All3 = ISNULL(SUM(CASE WHEN HasLoadTs = 1 AND HasSource = 1 AND HasBatch = 1 THEN 1 ELSE 0 END), 0),
           @Any = ISNULL(SUM(CASE WHEN HasLoadTs = 1 OR HasSource = 1 OR HasBatch = 1 THEN 1 ELSE 0 END), 0),
           @BareList = ISNULL(LEFT(STRING_AGG(CASE WHEN HasLoadTs = 0 AND HasSource = 0 AND HasBatch = 0
                                                   THEN CONVERT(NVARCHAR(MAX), sch + '.' + tbl) END, ', '), 350), '')
    FROM flagged;
END TRY
BEGIN CATCH
    SET @Probe = 0;
    SET @Finding = 'Column metadata unavailable: ' + LEFT(ERROR_MESSAGE(), 200);
END CATCH;

SET @Total = ISNULL(@Total, 0);
SET @All3 = ISNULL(@All3, 0);
SET @Any = ISNULL(@Any, 0);

DECLARE @AllPct DECIMAL(9,2) = ISNULL(100.0 * @All3 / NULLIF(@Total, 0), 0);
DECLARE @AnyPct DECIMAL(9,2) = ISNULL(100.0 * @Any / NULLIF(@Total, 0), 0);

IF @Probe = 1
BEGIN
    SET @Score = CASE
        WHEN @Total = 0 THEN 0
        WHEN @AllPct >= 80 THEN 3
        WHEN @AllPct >= 50 OR @AnyPct >= 80 THEN 2
        WHEN @Any > 0 THEN 1
        ELSE 0 END;

    IF @Total = 0
        SET @Finding = 'No user tables found in ' + @DatabaseQueried + '; no source metadata to capture';
    ELSE
        SET @Finding = CONCAT(@DatabaseQueried, ': ', @All3, ' of ', @Total, ' table(s) (',
            CONVERT(NVARCHAR(10), @AllPct), '%) carry load timestamp, source and batch id; ',
            @Any, ' (', CONVERT(NVARCHAR(10), @AnyPct), '%) carry at least one',
            CASE WHEN LEN(@BareList) > 0 THEN '; no lineage columns on ' + @BareList ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
