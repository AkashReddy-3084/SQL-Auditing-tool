-- Checklist: Completeness: all expected sources/batches received
-- Scope: DATABASE
-- Scoring: 3 = control tables and matching control columns are present; 2 = control tables are present with no matching columns; 1 = matching control columns exist without a control table; 0 = no control evidence or evidence is unavailable
-- NOTE: Automated evidence identifies control structures; actual batch receipt completeness requires runtime data and human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Batch completeness evidence unavailable';
DECLARE @ControlTableCount INT = 0;
DECLARE @ControlColumnCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @ControlTableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND (name LIKE N'%batch%' OR name LIKE N'%control%'
           OR name LIKE N'%load%log%' OR name LIKE N'%etl%log%'
           OR name LIKE N'%watermark%' OR name LIKE N'%manifest%');

    SELECT @ControlColumnCount = COUNT(*)
    FROM sys.columns AS c
    INNER JOIN sys.tables AS t ON t.object_id = c.object_id
    WHERE t.is_ms_shipped = 0
      AND (c.name LIKE N'%source%system%'
           OR c.name LIKE N'%batch%id%' OR c.name LIKE N'%expected%');
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @ControlTableCount > 0 AND @ControlColumnCount > 0 THEN 3
    WHEN @ControlTableCount > 0 THEN 2
    WHEN @ControlColumnCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'control tables = ', @ControlTableCount,
    N'; matching source/batch/expected columns = ', @ControlColumnCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more catalog sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
