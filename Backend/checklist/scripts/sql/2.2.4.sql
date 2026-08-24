SET NOCOUNT ON;

DECLARE @Score INT = 1;
DECLARE @Result NVARCHAR(50);
DECLARE @Finding NVARCHAR(MAX) = 'CDC and Change Tracking are not enabled in this database.';
DECLARE @DatabaseQueried NVARCHAR(MAX) = ISNULL(DB_NAME(), 'None');

IF DB_ID() <= 4 OR @DatabaseQueried = 'None'
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    DECLARE @CdcEnabled BIT = 0;
    DECLARE @CtEnabled BIT = 0;
    DECLARE @Retention INT = NULL;
    DECLARE @RetentionUnits NVARCHAR(50) = NULL;

    SELECT TOP 1 @CdcEnabled = ISNULL(is_cdc_enabled, 0)
    FROM sys.databases 
    WHERE database_id = DB_ID();

    IF @CdcEnabled = 1
    BEGIN
        SET @Finding = 'CDC is enabled in this database. Manual review required to ensure capture/cleanup jobs run successfully and retention is appropriate.';
        SET @Score = 2;
    END
    ELSE
    BEGIN
        SELECT TOP 1 @Retention = ISNULL(retention_period, 0), @RetentionUnits = ISNULL(retention_period_units_desc, '') 
        FROM sys.change_tracking_databases 
        WHERE database_id = DB_ID();

        IF @Retention IS NOT NULL
        BEGIN
            SET @Finding = 'Change Tracking is enabled. Retention: ' + CAST(ISNULL(@Retention, 0) AS NVARCHAR(10)) + ' ' + ISNULL(@RetentionUnits, '') + '. Manual review required to ensure cleanup is occurring and not causing bloat.';
            SET @Score = 2;
        END
    END
END

SET @Result = CASE @Score WHEN 1 THEN 'Pass' WHEN 2 THEN 'NeedsReview' ELSE 'Fail' END;

SELECT
    ISNULL(@Result, 'Fail') AS Result,
    ISNULL(@Score, 3) AS Score,
    ISNULL(@DatabaseQueried, 'None') AS DatabaseQueried,
    ISNULL(@Finding, 'No database found to be queried') AS Finding;