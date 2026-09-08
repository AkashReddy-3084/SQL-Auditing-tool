-- Checklist: Alert thresholds tuned to avoid fatigue
-- Scope: SERVER
-- Scoring: 3 = every enabled alert has a threshold (severity, error number or performance condition) and a response delay; 2 = some enabled alerts tuned, or platform-managed alerting; 1 = enabled alerts exist with no threshold and no response delay; 0 = no enabled alerts

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'SQL Agent alert metadata could not be read';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Alerts INT = 0;
DECLARE @Enabled INT = 0;
DECLARE @Tuned INT = 0;
DECLARE @MaxFires INT = 0;
DECLARE @UntunedNames NVARCHAR(MAX) = 'none';
DECLARE @Collected INT = 0;
DECLARE @Sql NVARCHAR(MAX);

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: SQL Server Agent alerts do not exist on this platform, so no in-engine alert thresholds or response delays could be read; alert rules and their thresholds are defined in Azure Monitor outside the database engine.';
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @a = COUNT(*), @e = ISNULL(SUM(CASE WHEN enabled = 1 THEN 1 ELSE 0 END), 0), @t = ISNULL(SUM(CASE WHEN enabled = 1 AND delay_between_responses > 0 AND (performance_condition IS NOT NULL OR severity >= 17 OR message_id <> 0) THEN 1 ELSE 0 END), 0), @f = ISNULL(MAX(occurrence_count), 0), @n = ISNULL(STRING_AGG(CASE WHEN enabled = 1 AND (delay_between_responses = 0 OR (performance_condition IS NULL AND severity < 17 AND message_id = 0)) THEN CONVERT(NVARCHAR(MAX), name) END, '', ''), ''none'') FROM msdb.dbo.sysalerts;';
        EXEC sys.sp_executesql @Sql, N'@a INT OUTPUT, @e INT OUTPUT, @t INT OUTPUT, @f INT OUTPUT, @n NVARCHAR(MAX) OUTPUT',
             @a = @Alerts OUTPUT, @e = @Enabled OUTPUT, @t = @Tuned OUTPUT, @f = @MaxFires OUTPUT, @n = @UntunedNames OUTPUT;
        SET @Collected = 1;
    END TRY
    BEGIN CATCH
        SET @Collected = 0;
    END CATCH;

    SET @Alerts = ISNULL(@Alerts, 0);
    SET @Enabled = ISNULL(@Enabled, 0);
    SET @Tuned = ISNULL(@Tuned, 0);
    SET @MaxFires = ISNULL(@MaxFires, 0);
    SET @UntunedNames = ISNULL(@UntunedNames, 'none');

    IF @Collected = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'SQL Agent alert metadata in msdb.dbo.sysalerts could not be read with the audit login, so alert thresholds and response delays could not be assessed.';
    END
    ELSE
    BEGIN
        SET @Score = CASE
            WHEN @Enabled = 0 THEN 0
            WHEN @Tuned = @Enabled THEN 3
            WHEN @Tuned > 0 THEN 2
            ELSE 1
        END;

        SET @Finding = CASE
            WHEN @Enabled = 0 THEN CONCAT('No enabled SQL Agent alerts exist (', @Alerts,
                ' alert definition(s) found, all disabled), so there are no thresholds to tune and no alert traffic is produced.')
            ELSE CONCAT('Alert definitions = ', @Alerts, ', enabled = ', @Enabled,
                ', enabled alerts carrying both a threshold (severity >= 17, a specific error number or a performance condition) and a response delay = ', @Tuned,
                ', untuned enabled alerts = ', @Enabled - @Tuned, ' [', LEFT(@UntunedNames, 800),
                ']; highest recorded occurrence_count on any alert = ', @MaxFires, '.')
        END;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;