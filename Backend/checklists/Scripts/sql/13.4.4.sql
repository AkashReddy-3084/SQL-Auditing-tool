-- Checklist: Code is self-documenting or well-commented for complex logic
-- Scope: DATABASE
-- Scoring: 3 = no complex module lacks comments (or no complex modules exist); 2 = under 25 percent uncommented; 1 = under 50 percent uncommented; 0 = 50 percent or more uncommented

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Module definitions could not be inspected in the current database';
DECLARE @Modules INT = 0;
DECLARE @Complex INT = 0;
DECLARE @Uncommented INT = 0;
DECLARE @Bad NVARCHAR(MAX) = '';
DECLARE @Pct DECIMAL(9,4) = 0;
DECLARE @Readable BIT = 0;

BEGIN TRY
    SELECT @Modules = COUNT(*)
    FROM sys.sql_modules AS sm
    JOIN sys.objects AS o ON o.object_id = sm.object_id
    WHERE o.is_ms_shipped = 0 AND sm.definition IS NOT NULL;

    ;WITH c AS
    (
        SELECT QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name) AS FullName,
               CASE WHEN sm.definition LIKE '%--%' OR sm.definition LIKE '%/*%' THEN 1 ELSE 0 END AS HasComment
        FROM sys.sql_modules AS sm
        JOIN sys.objects AS o ON o.object_id = sm.object_id
        WHERE o.is_ms_shipped = 0
          AND sm.definition IS NOT NULL
          AND (DATALENGTH(sm.definition) >= 3000
            OR sm.definition LIKE '%CURSOR%'
            OR sm.definition LIKE '%WHILE%'
            OR sm.definition LIKE '%MERGE %'
            OR sm.definition LIKE '%sp_executesql%'
            OR sm.definition LIKE '%PIVOT%')
    )
    SELECT @Complex = COUNT(*),
           @Uncommented = ISNULL(SUM(CASE WHEN HasComment = 0 THEN 1 ELSE 0 END), 0),
           @Bad = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX),
                      CASE WHEN HasComment = 0 THEN FullName END), ', '), 500), '')
    FROM c;

    SET @Readable = 1;
END TRY
BEGIN CATCH
    SET @Readable = 0;
END CATCH;

SET @Pct = ISNULL(CONVERT(DECIMAL(9,4), @Uncommented) / NULLIF(@Complex, 0), 0);

SET @Score = CASE
                WHEN @Readable = 0 THEN 0
                WHEN @Complex = 0 OR @Uncommented = 0 THEN 3
                WHEN @Pct < 0.25 THEN 2
                WHEN @Pct < 0.50 THEN 1
                ELSE 0
             END;

SET @Finding = CASE
    WHEN @Readable = 0
        THEN 'sys.sql_modules could not be read, so comment coverage of complex logic is unknown'
    WHEN @Complex = 0
        THEN CONCAT(@Modules, ' T-SQL module(s) present, none of which contain complex constructs (cursors, loops, MERGE, dynamic SQL, PIVOT) or exceed 1500 characters, so no uncommented complex logic exists')
    WHEN @Uncommented = 0
        THEN CONCAT('All ', @Complex, ' complex module(s) of ', @Modules, ' total contain inline or block comments')
    ELSE CONCAT(@Uncommented, ' of ', @Complex, ' complex module(s) carry no comment at all (',
                CONVERT(DECIMAL(9,1), @Pct * 100), ' percent): ', @Bad)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;