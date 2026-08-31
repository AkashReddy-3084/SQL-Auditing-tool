BEGIN TRY
    SET NOCOUNT ON;
    
    DECLARE @MaxDOP INT;
    DECLARE @CostThreshold INT;
    DECLARE @Result NVARCHAR(255);
    DECLARE @Score INT = 0;
    DECLARE @Finding NVARCHAR(MAX);
    DECLARE @DatabaseQueried NVARCHAR(128) = 'master';

    SELECT @MaxDOP = CAST(value_in_use AS INT)
    FROM sys.configurations
    WHERE name = 'max degree of parallelism';

    SELECT @CostThreshold = CAST(value_in_use AS INT)
    FROM sys.configurations
    WHERE name = 'cost threshold for parallelism';

    IF @MaxDOP IS NOT NULL AND @CostThreshold IS NOT NULL
    BEGIN
        SET @Score = 3; 
        SET @Finding = 'Performance: max degree of parallelism is ' + CAST(@MaxDOP AS NVARCHAR(10)) + 
                       ', cost threshold for parallelism is ' + CAST(@CostThreshold AS NVARCHAR(10)) + '.';
    END
    ELSE
    BEGIN
        SET @Score = 0; 
        SET @Finding = 'Error: Could not retrieve MAXDOP or cost threshold configurations.';
    END

    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    SELECT 
        @Result AS Result,
        @Score AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding AS Finding;
END TRY
BEGIN CATCH
    SELECT 
        'Fail' AS Result,
        0 AS Score,
        'master' AS DatabaseQueried,
        'Error: ' + ERROR_MESSAGE() AS Finding;
END CATCH