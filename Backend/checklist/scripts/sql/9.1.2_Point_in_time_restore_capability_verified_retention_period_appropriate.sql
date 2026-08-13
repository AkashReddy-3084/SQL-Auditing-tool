-- Checklist: Point-in-time restore capability verified (retention period appropriate)
-- Scope: SERVER
-- Scoring: 0=SIMPLE recovery/no log backups; 1=FULL/BULK_LOGGED but infrequent logs or short retention (<7d); 2=FULL recovery + daily logs + 7-30d retention; 3=FULL recovery + frequent logs + >30d retention. Azure SQL DB auto-scores 3.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition = 5 -- Azure SQL DB (PITR is fully managed)
BEGIN
    SET @Score = 3;
END
ELSE
BEGIN
    DECLARE @HasSimpleRecovery BIT = 0;
    SELECT @HasSimpleRecovery = MAX(CASE WHEN recovery_model_desc = 'SIMPLE' THEN 1 ELSE 0 END)
    FROM sys.databases WHERE database_id > 4 AND state = 0;

    IF @HasSimpleRecovery = 1
    BEGIN
        SET @Score = 0;
    END
    ELSE
    BEGIN
        DECLARE @OldestLogBackupDate DATETIME;
        DECLARE @LogBackupDays INT;

        SELECT @OldestLogBackupDate = MIN(backup_start_date),
               @LogBackupDays = COUNT(DISTINCT CONVERT(DATE, backup_start_date))
        FROM msdb.dbo.backupset WITH (NOLOCK)
        WHERE database_name IN (SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0)
          AND backup_start_date >= DATEADD(DAY, -90, GETDATE())
          AND type = 'L';

        IF @OldestLogBackupDate IS NULL OR @LogBackupDays = 0
        BEGIN
            SET @Score = 0;
        END
        ELSE
        BEGIN
            DECLARE @RetentionDays INT = DATEDIFF(DAY, @OldestLogBackupDate, GETDATE());
            DECLARE @LogFreqScore INT = CASE WHEN @LogBackupDays >= 20 THEN 2 WHEN @LogBackupDays >= 7 THEN 1 ELSE 0 END;
            DECLARE @RetentionScore INT = CASE WHEN @RetentionDays > 30 THEN 3 WHEN @RetentionDays >= 7 THEN 2 ELSE 1 END;

            SET @Score = CASE
                WHEN @LogFreqScore = 0 OR @RetentionScore = 1 THEN 1
                WHEN @LogFreqScore = 1 AND @RetentionScore = 2 THEN 2
                WHEN @LogFreqScore = 2 AND @RetentionScore >= 2 THEN 3
                ELSE 1
            END;
        END
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;