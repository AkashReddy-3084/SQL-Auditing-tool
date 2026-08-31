SET NOCOUNT ON;
BEGIN TRY
    DECLARE @MaxMemoryMB BIGINT;
    DECLARE @PhysicalMemoryMB BIGINT;
    DECLARE @DefaultMax INT = 2147483647;
    
    SELECT @MaxMemoryMB = CAST(value_in_use AS BIGINT)
    FROM sys.configurations
    WHERE name = 'max server memory (MB)';
    
    SELECT @PhysicalMemoryMB = physical_memory_kb / 1024
    FROM sys.dm_os_sys_info;
    
    DECLARE @Score INT;
    DECLARE @Result VARCHAR(20);
    DECLARE @Finding NVARCHAR(255);
    
    IF @MaxMemoryMB = @DefaultMax
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Max server memory is set to the default value (' + CAST(@MaxMemoryMB AS VARCHAR) + ' MB).';
    END
    ELSE IF @MaxMemoryMB <= (@PhysicalMemoryMB - 2048)
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Max server memory (' + CAST(@MaxMemoryMB AS VARCHAR) + ' MB) is configured properly below physical memory (' + CAST(@PhysicalMemoryMB AS VARCHAR) + ' MB).';
    END
    ELSE
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Max server memory (' + CAST(@MaxMemoryMB AS VARCHAR) + ' MB) is customized but might be too close to physical memory (' + CAST(@PhysicalMemoryMB AS VARCHAR) + ' MB).';
    END
    
    SET @Result = CASE 
        WHEN @Score = 1 THEN 'Pass' 
        WHEN @Score = 3 THEN 'Fail' 
        ELSE 'NeedsReview' 
    END;
    
    SELECT 
        @Result AS Result,
        @Score AS Score,
        'SERVER' AS DatabaseQueried,
        @Finding AS Finding;
END TRY
BEGIN CATCH
    SELECT 
        'NeedsReview' AS Result,
        2 AS Score,
        'SERVER' AS DatabaseQueried,
        ERROR_MESSAGE() AS Finding;
END CATCH