SET NOCOUNT ON;

DECLARE @DatabaseName sysname = DB_NAME();
DECLARE @DatabaseQueried nvarchar(128);
DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @Finding nvarchar(max);

IF DB_ID() <= 4 OR DATABASEPROPERTYEX(@DatabaseName, 'Updateability') IS NULL
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SET @DatabaseQueried = @DatabaseName;

    IF ISNULL(HAS_PERMS_BY_NAME(@DatabaseName, 'DATABASE', 'VIEW DEFINITION'), 0) = 0
       AND ISNULL(HAS_PERMS_BY_NAME(@DatabaseName, 'DATABASE', 'CONTROL'), 0) = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Unable to inspect module definitions because the caller does not have VIEW DEFINITION or CONTROL permission in database ' + QUOTENAME(@DatabaseName) + N'.';
    END
    ELSE
    BEGIN
        CREATE TABLE #DynamicSqlFindings
        (
            ModuleName nvarchar(517) NOT NULL,
            Issue nvarchar(200) NOT NULL
        );

        ;WITH ModuleDefinitions AS
        (
            SELECT
                QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) AS ModuleName,
                UPPER(REPLACE(REPLACE(REPLACE(REPLACE(sm.definition, N' ', N''), CHAR(9), N''), CHAR(10), N''), CHAR(13), N'')) AS CompactDefinition,
                UPPER(sm.definition) AS UpperDefinition
            FROM sys.sql_modules AS sm
            INNER JOIN sys.objects AS o
                ON o.object_id = sm.object_id
            INNER JOIN sys.schemas AS s
                ON s.schema_id = o.schema_id
            WHERE o.is_ms_shipped = 0
              AND sm.definition IS NOT NULL
              AND o.type IN ('P', 'PC', 'FN', 'IF', 'TF', 'TR', 'V')
        )
        INSERT #DynamicSqlFindings (ModuleName, Issue)
        SELECT
            md.ModuleName,
            CASE
                WHEN md.CompactDefinition LIKE N'%EXEC(@%'
                  OR md.CompactDefinition LIKE N'%EXECUTE(@%'
                    THEN N'Direct EXEC/EXECUTE of a variable was detected.'
                ELSE N'sp_executesql was found without a visible parameter declaration.'
            END
        FROM ModuleDefinitions AS md
        WHERE md.CompactDefinition LIKE N'%EXEC(@%'
           OR md.CompactDefinition LIKE N'%EXECUTE(@%'
           OR
           (
               md.UpperDefinition LIKE N'%SP_EXECUTESQL%'
               AND md.UpperDefinition NOT LIKE N'%SP_EXECUTESQL%N''@%'
               AND md.UpperDefinition NOT LIKE N'%SP_EXECUTESQL%@PARAMS%'
           );

        DECLARE @FindingCount int = (SELECT COUNT(*) FROM #DynamicSqlFindings);
        DECLARE @Examples nvarchar(max);

        SELECT @Examples = STUFF
        (
            (
                SELECT TOP (10)
                    N'; ' + f.ModuleName + N': ' + f.Issue
                FROM #DynamicSqlFindings AS f
                ORDER BY f.ModuleName, f.Issue
                FOR XML PATH(''), TYPE
            ).value('.', 'nvarchar(max)'),
            1,
            2,
            N''
        );

        IF @FindingCount = 0
        BEGIN
            SET @Score = 3;
            SET @Finding = N'No module definitions containing direct variable EXEC or apparently unparameterized sp_executesql calls were found.';
        END
        ELSE
        BEGIN
            SET @Score = 1;
            SET @Finding = CONCAT
            (
                @FindingCount,
                N' module(s) contain potentially unparameterized dynamic SQL. Review candidates: ',
                COALESCE(@Examples, N'No example available.'),
                CASE WHEN @FindingCount > 10 THEN N'; additional candidates omitted.' ELSE N'' END
            );
        END;
    END;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;