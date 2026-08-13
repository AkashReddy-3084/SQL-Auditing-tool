-- Checklist: Breach / incident notification process documented
-- Scope: SERVER
-- Scoring: 0=No documentation found, 1=Partial mentions, 2=Structured documentation in extended properties (max capped at 2)
SET NOCOUNT ON;

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalDocCount INT = 0;
DECLARE @DBName NVARCHAR(128);
DECLARE @SQL NVARCHAR(MAX);
DECLARE @DBCount INT;

-- Iterate through all online user databases to satisfy SERVER scope
DECLARE db_cursor CURSOR FOR
SELECT QUOTENAME(name)
FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DBName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SQL = N'
    SELECT @DBCount = COUNT(*)
    FROM ' + @DBName + N'.sys.extended_properties ep
    JOIN ' + @DBName + N'.sys.objects o ON ep.major_id = o.object_id AND ep.major_type = ''U''
    WHERE SQL_VARIANT_PROPERTY(ep.value, ''BaseType'') IN (''varchar'', ''nvarchar'', ''char'', ''nchar'')
      AND (CONVERT(NVARCHAR(MAX), ep.value) LIKE ''%breach%''
         OR CONVERT(NVARCHAR(MAX), ep.value) LIKE ''%incident%''
         OR CONVERT(NVARCHAR(MAX), ep.value) LIKE ''%notification%''
         OR CONVERT(NVARCHAR(MAX), ep.value) LIKE ''%process%'');';

    EXEC sp_executesql @SQL, N'@DBCount INT OUTPUT', @DBCount = @DBCount OUTPUT;
    SET @TotalDocCount = @TotalDocCount + ISNULL(@DBCount, 0);
    FETCH NEXT FROM db_cursor INTO @DBName;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Apply scoring logic (max capped at 2 per checklist requirements)
IF @TotalDocCount > 0
BEGIN
    SET @Score = 2;
END
ELSE
BEGIN
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN ''Pass'' ELSE ''Fail'' END;

-- NOTE: This script provides automated proxy evidence. Full compliance requires human review of actual policy documentation.
SELECT @Result AS Result, @Score AS Score;