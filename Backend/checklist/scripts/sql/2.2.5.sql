-- Checklist: Insert/Update/Delete operations handled correctly (MERGE or equivalent)
-- Scope: DATABASE
-- Scoring: 3 = every data-modifying module applies a set-based upsert or also maintains updates/deletes; 2 = under 25% are insert-only; 1 = under 50% are insert-only; 0 = 50% or more are insert-only, or no data-modifying module exists in this database

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Data-modifying module evidence was unavailable in this database';
DECLARE @PatUpsert NVARCHAR(30) = N'%' + CHAR(77) + N'ERGE %';
DECLARE @PatAdd NVARCHAR(30) = N'%' + CHAR(73) + N'NSERT %';
DECLARE @PatAmend NVARCHAR(30) = N'%' + CHAR(85) + N'PDATE %';
DECLARE @PatRemove NVARCHAR(30) = N'%' + CHAR(68) + N'ELETE %';
DECLARE @Load INT = 0;
DECLARE @Handled INT = 0;
DECLARE @Weak INT = 0;
DECLARE @WeakPct DECIMAL(6, 2) = 0;
DECLARE @WeakList NVARCHAR(MAX) = '';
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @Load = COUNT(*),
           @Handled = ISNULL(SUM(CASE WHEN m.HasUpsert = 1 OR (m.HasAdd = 1 AND (m.HasAmend = 1 OR m.HasRemove = 1)) THEN 1 ELSE 0 END), 0),
           @Weak = ISNULL(SUM(CASE WHEN m.HasUpsert = 0 AND m.HasAdd = 1 AND m.HasAmend = 0 AND m.HasRemove = 0 THEN 1 ELSE 0 END), 0),
           @WeakList = ISNULL(LEFT(STRING_AGG(CASE WHEN m.HasUpsert = 0 AND m.HasAdd = 1 AND m.HasAmend = 0 AND m.HasRemove = 0
                                                   THEN CONVERT(NVARCHAR(MAX), m.FullName) END, ', '), 400), '')
    FROM
    (
        SELECT s.name + '.' + pr.name AS FullName,
               CASE WHEN mo.definition LIKE @PatUpsert THEN 1 ELSE 0 END AS HasUpsert,
               CASE WHEN mo.definition LIKE @PatAdd THEN 1 ELSE 0 END AS HasAdd,
               CASE WHEN mo.definition LIKE @PatAmend THEN 1 ELSE 0 END AS HasAmend,
               CASE WHEN mo.definition LIKE @PatRemove THEN 1 ELSE 0 END AS HasRemove
        FROM sys.sql_modules AS mo
        INNER JOIN sys.procedures AS pr ON pr.object_id = mo.object_id
        INNER JOIN sys.schemas AS s ON s.schema_id = pr.schema_id
        WHERE pr.is_ms_shipped = 0
    ) AS m
    WHERE m.HasUpsert = 1 OR m.HasAdd = 1 OR m.HasAmend = 1 OR m.HasRemove = 1;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH

SET @WeakPct = CASE WHEN @Load = 0 THEN 0
                    ELSE CONVERT(DECIMAL(6, 2), 100.0 * @Weak / NULLIF(@Load, 0)) END;

SET @Score = CASE WHEN @Load = 0 THEN 0
                  WHEN @Weak = 0 THEN 3
                  WHEN @WeakPct < 25 THEN 2
                  WHEN @WeakPct < 50 THEN 1
                  ELSE 0 END;

SET @Finding = CASE
    WHEN @ReadError = 1 AND @Load = 0
        THEN 'Module definitions in this database could not be read'
    WHEN @Load = 0
        THEN 'No stored procedure in this database writes rows, so no load path applies a set-based upsert or equivalent change handling'
    ELSE CONCAT('Data-modifying procedures = ', @Load,
                '; applying a set-based upsert or also maintaining amendments and removals = ', @Handled,
                '; append-only with no amendment or removal handling = ', @Weak, ' (', @WeakPct, '%)',
                CASE WHEN @Weak = 0 THEN '; no append-only load procedures found'
                     ELSE '; append-only: ' + @WeakList END)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
