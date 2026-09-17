-- Checklist: Parallelism used appropriately (no unnecessary serial execution)
-- Scope: SERVER
-- Scoring: 3 = parallelism bounded above 1 with a cost threshold below 100; 2 = parallelism enabled but unbounded (MAXDOP 0) on a host with more than 8 schedulers; 1 = cost threshold of 100 or more suppressing parallel plans, or the setting is unreadable; 0 = MAXDOP = 1 forcing every query to run serially

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Parallelism configuration could not be read';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @MaxDop INT = -1;
DECLARE @CostThreshold INT = -1;
DECLARE @Cpu INT = 0;
DECLARE @Source NVARCHAR(60) = 'sys.configurations';

BEGIN TRY
    SELECT @Cpu = ISNULL(cpu_count, 0) FROM sys.dm_os_sys_info;
END TRY
BEGIN CATCH
    SET @Cpu = 0;
END CATCH

IF @Engine = 5
BEGIN
    SET @Source = 'sys.database_scoped_configurations';
    BEGIN TRY
        SELECT TOP (1) @MaxDop = CONVERT(INT, value)
        FROM sys.database_scoped_configurations
        WHERE name = 'MAXDOP';
    END TRY
    BEGIN CATCH
        SET @MaxDop = -1;
    END CATCH
END
ELSE
BEGIN
    BEGIN TRY
        SELECT @MaxDop = CONVERT(INT, value_in_use)
        FROM sys.configurations
        WHERE name = 'max degree of parallelism';

        SELECT @CostThreshold = CONVERT(INT, value_in_use)
        FROM sys.configurations
        WHERE name = 'cost threshold for parallelism';
    END TRY
    BEGIN CATCH
        SET @MaxDop = -1;
    END CATCH
END

IF @MaxDop = 1
    SET @Score = 0;
ELSE IF @CostThreshold >= 100
    SET @Score = 1;
ELSE IF @MaxDop = 0 AND @Cpu > 8
    SET @Score = 2;
ELSE IF @MaxDop < 0
    SET @Score = 1;
ELSE
    SET @Score = 3;

SET @Finding = CONCAT('max degree of parallelism = ',
    CASE WHEN @MaxDop < 0 THEN 'unavailable' ELSE CONVERT(NVARCHAR(20), @MaxDop) END,
    ' (read from ', @Source, '); cost threshold for parallelism = ',
    CASE WHEN @CostThreshold < 0 THEN 'not exposed on this engine' ELSE CONVERT(NVARCHAR(20), @CostThreshold) END,
    '; visible scheduler/CPU count = ', @Cpu, '. ',
    CASE WHEN @MaxDop = 1 THEN 'MAXDOP 1 forces every query to run serially.'
         WHEN @CostThreshold >= 100 THEN 'The cost threshold is high enough that most plans stay serial.'
         WHEN @MaxDop = 0 AND @Cpu > 8 THEN 'Parallelism is enabled but unbounded on a host with more than 8 schedulers.'
         WHEN @MaxDop < 0 THEN 'The parallelism setting could not be read on this engine.'
         ELSE 'Parallelism is enabled and bounded, so statements above the cost threshold can use a parallel plan.'
    END);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
