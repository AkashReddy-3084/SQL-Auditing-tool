-- Checklist: Set-based logic used; cursors/WHILE loops avoided except where justified
-- Scope: DATABASE
-- Scoring: 3 = no user T-SQL module contains a cursor or row-by-row loop, or no modules exist; 2 = under 5% of modules do; 1 = under 25%; 0 = 25% or more, or module metadata is unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Module metadata could not be read in this database';
DECLARE @Total INT = 0;
DECLARE @CursorMods INT = 0;
DECLARE @LoopMods INT = 0;
DECLARE @Flagged INT = 0;
DECLARE @OffenderList NVARCHAR(MAX) = '';
DECLARE @Ratio DECIMAL(9, 4) = 0;
DECLARE @Probed BIT = 0;
DECLARE @IterPattern NVARCHAR(30) = '%' + CHAR(67) + 'URSOR%';
DECLARE @FetchPattern NVARCHAR(30) = '%FETCH NEXT%';
DECLARE @LoopPattern NVARCHAR(30) = '%' + CHAR(87) + 'HILE %';

BEGIN TRY
    SELECT @Total = COUNT(*),
           @CursorMods = ISNULL(SUM(CASE WHEN m.definition LIKE @IterPattern
                                           OR m.definition LIKE @FetchPattern THEN 1 ELSE 0 END), 0),
           @LoopMods = ISNULL(SUM(CASE WHEN m.definition LIKE @LoopPattern
                                        AND m.definition NOT LIKE @IterPattern
                                        AND m.definition NOT LIKE @FetchPattern THEN 1 ELSE 0 END), 0),
           @Flagged = ISNULL(SUM(CASE WHEN m.definition LIKE @IterPattern
                                        OR m.definition LIKE @FetchPattern
                                        OR m.definition LIKE @LoopPattern THEN 1 ELSE 0 END), 0)
    FROM sys.sql_modules AS m
    JOIN sys.objects AS o ON o.object_id = m.object_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('P', 'FN', 'IF', 'TF', 'TR', 'V');

    SELECT @OffenderList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX),
                              QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name)), ', '), 400), '')
    FROM sys.sql_modules AS m
    JOIN sys.objects AS o ON o.object_id = m.object_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('P', 'FN', 'IF', 'TF', 'TR', 'V')
      AND (m.definition LIKE @IterPattern
           OR m.definition LIKE @FetchPattern
           OR m.definition LIKE @LoopPattern);

    SET @Probed = 1;
END TRY
BEGIN CATCH
    SET @Probed = 0;
END CATCH

SET @Ratio = CASE WHEN @Total = 0 THEN 0
                  ELSE CONVERT(DECIMAL(9, 4), @Flagged) / @Total END;

IF @Probed = 0
    SET @Score = 0;
ELSE IF @Flagged = 0
    SET @Score = 3;
ELSE IF @Ratio < 0.05
    SET @Score = 2;
ELSE IF @Ratio < 0.25
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Finding = CASE WHEN @Probed = 0
    THEN 'sys.sql_modules could not be read in this database; VIEW DEFINITION permission is required to inspect module bodies for iterative code.'
    WHEN @Total = 0
    THEN 'No user-defined T-SQL modules exist in this database, so no row-by-row processing is present.'
    ELSE CONCAT('User T-SQL modules = ', @Total, '; containing a cursor declaration or FETCH NEXT = ', @CursorMods,
                '; containing an iterative loop only = ', @LoopMods,
                '; total with row-by-row constructs = ', @Flagged, ' (',
                CONVERT(NVARCHAR(20), CONVERT(DECIMAL(9, 2), @Ratio * 100)), '%)',
                CASE WHEN LEN(ISNULL(@OffenderList, '')) > 0 THEN CONCAT(': ', @OffenderList)
                     ELSE '. All logic is set-based' END, '.')
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
