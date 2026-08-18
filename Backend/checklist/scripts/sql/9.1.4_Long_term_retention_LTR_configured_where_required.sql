-- Checklist: Long-term retention (LTR) configured where required
-- Scope: SERVER
-- Scoring: 0: LTR not configured or no history found. 1: Partial history or limited retention. 2: LTR configured but history incomplete. 3: LTR fully configured with consistent history.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT;
DECLARE @LtrCount INT = 0;
DECLARE @Sql NVARCHAR(MAX);

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
SET @DatabaseQueried = 'master';

IF @EngineEdition IN (5, 8) -- Azure SQL Database or Azure SQL Managed Instance
BEGIN
    IF OBJECT_ID('sys.dm_rtl_backup_history') IS NOT NULL
    BEGIN
        SET @Sql = N'SELECT @LtrCount = COUNT(*) FROM sys.dm_rtl_backup_history;';
        EXEC sp_executesql @Sql, N'@LtrCount INT OUTPUT', @LtrCount OUTPUT;

        IF @LtrCount > 0
        BEGIN
            SET @Score = 3;
            SET @Finding = 'LTR configured. ' + CAST(@LtrCount AS NVARCHAR) + ' geo-backup/LTR history records found.';
        END
        ELSE
        BEGIN
            SET @Score = 0;
            SET @Finding = 'LTR not configured. No geo-backup/LTR history records found.';
        END
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = 'LTR DMV not available. Configuration cannot be fully verified.';
    END
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = 'LTR is an Azure SQL feature. Not applicable for on-premises SQL Server.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;