SET NOCOUNT ON;

DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @DatabaseQueried sysname;
DECLARE @Finding nvarchar(2000);
DECLARE @TotalTryCatchModules int;
DECLARE @ProperHandlingModules int;
DECLARE @MissingHandlingModules int;

IF DB_ID() <= 4
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END;
ELSE
BEGIN
    SET @DatabaseQueried = DB_NAME();

    SELECT
        @TotalTryCatchModules = COUNT(*),
        @ProperHandlingModules = COALESCE(SUM(CASE
            WHEN UPPER(m.definition) LIKE N'%THROW%'
              OR UPPER(m.definition) LIKE N'%RAISERROR%'
              OR (
                    UPPER(m.definition) LIKE N'%ERROR_MESSAGE%'
                AND (
                       UPPER(m.definition) LIKE N'%INSERT%INTO%'
                    OR UPPER(m.definition) LIKE N'%EXEC%'
                )
              )
            THEN 1 ELSE 0 END), 0)
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o
        ON o.object_id = m.object_id
    WHERE o.is_ms_shipped = 0
      AND m.definition IS NOT NULL
      AND UPPER(m.definition) LIKE N'%BEGIN%TRY%'
      AND UPPER(m.definition) LIKE N'%BEGIN%CATCH%';

    SET @MissingHandlingModules = @TotalTryCatchModules - @ProperHandlingModules;

    SET @Score = CASE
        WHEN @TotalTryCatchModules > 0
         AND @ProperHandlingModules = @TotalTryCatchModules THEN 3
        WHEN @TotalTryCatchModules > 0
         AND @ProperHandlingModules * 100 >= @TotalTryCatchModules * 80 THEN 2
        WHEN @ProperHandlingModules > 0 THEN 1
        ELSE 0
    END;

    SET @Finding = CONCAT(
        N'TRY...CATCH modules: ', @TotalTryCatchModules,
        N'; modules with THROW/RAISERROR or detected error logging: ', @ProperHandlingModules,
        N'; modules missing detected handling: ', @MissingHandlingModules,
        N'. Static pattern matching may require review for custom logging abstractions.'
    );
END;

SET @Result = CASE
    WHEN @Score = 3 THEN N'Pass'
    WHEN @Score IN (1, 2) THEN N'Partial'
    ELSE N'Fail'
END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;