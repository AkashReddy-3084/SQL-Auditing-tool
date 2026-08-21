-- Checklist: Parallelism used appropriately (no unnecessary serial execution)
-- Scope: SERVER
-- Scoring: 3: MAXDOP is 0 or >=2 AND CTP is 5-50. 2: MAXDOP is 0 or >=2 AND CTP is outside 5-50. 1: MAXDOP is 1 (forces serial). 0: MAXDOP is 1 AND CTP is outside 5-50. Azure SQL DB scores 3 (platform-managed).

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @MaxDop INT;
DECLARE @Ctp INT;
DECLARE @EngineEdition INT;

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: Parallelism is automatically managed by the platform. No manual configuration required.';
END
ELSE
BEGIN
    SELECT 
        @MaxDop = CONVERT(INT, value_in_use)
    FROM sys.configurations
    WHERE name = 'max degree of parallelism';

    SELECT 
        @Ctp = CONVERT(INT, value_in_use)
    FROM sys.configurations
    WHERE name = 'cost threshold for parallelism';

    IF @MaxDop IS NULL OR @Ctp IS NULL
    BEGIN
        SET @Score = 0;
        SET @Finding = 'Unable to retrieve parallelism settings from sys.configurations.';
    END
    ELSE
    BEGIN
        IF @MaxDop = 1
        BEGIN
            IF @Ctp BETWEEN 5 AND 50
                SET @Score = 1;
            ELSE
                SET @Score = 0;
        END
        ELSE
        BEGIN
            IF @Ctp BETWEEN 5 AND 50
                SET @Score = 3;
            ELSE
                SET @Score = 2;
        END

        SET @Finding = 'max degree of parallelism = ' + CAST(@MaxDop AS NVARCHAR(10)) + '; cost threshold for parallelism = ' + CAST(@Ctp AS NVARCHAR(10));
    END
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;