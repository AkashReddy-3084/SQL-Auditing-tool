-- Checklist: Backups stored redundantly / geo-redundant where required
-- Scope: SERVER
-- Scoring: 0: No backup history found. 1: Backups exist but only on a single local path. 2: Backups configured to multiple local/UNC paths. 3: Backups stored in cloud storage (Azure Blob URLs) or Azure PaaS (inherent geo-redundancy).

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition IN (5, 8)
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure PaaS service provides geo-redundant backups by default.';
END
ELSE
BEGIN
    DECLARE @BackupPaths TABLE (
        PathType NVARCHAR(50),
        PathCount INT,
        SamplePath NVARCHAR(256)
    );

    INSERT INTO @BackupPaths
    SELECT 
        CASE 
            WHEN bmf.physical_device_name LIKE 'http://%' OR bmf.physical_device_name LIKE 'https://%' THEN 'Cloud'
            WHEN bmf.physical_device_name LIKE '\\%' THEN 'UNC'
            ELSE 'Local'
        END AS PathType,
        COUNT(DISTINCT bmf.physical_device_name) AS PathCount,
        MIN(bmf.physical_device_name) AS SamplePath
    FROM msdb.dbo.backupmediafamily bmf
    INNER JOIN msdb.dbo.backupset bs ON bmf.media_set_id = bs.media_set_id
    WHERE bmf.media_set_id IN (
        SELECT TOP 100 media_set_id 
        FROM msdb.dbo.backupset 
        ORDER BY backup_start_date DESC
    )
    GROUP BY 
        CASE 
            WHEN bmf.physical_device_name LIKE 'http://%' OR bmf.physical_device_name LIKE 'https://%' THEN 'Cloud'
            WHEN bmf.physical_device_name LIKE '\\%' THEN 'UNC'
            ELSE 'Local'
        END;

    DECLARE @CloudCount INT = ISNULL((SELECT SUM(PathCount) FROM @BackupPaths WHERE PathType = 'Cloud'), 0);
    DECLARE @TotalPaths INT = ISNULL((SELECT SUM(PathCount) FROM @BackupPaths), 0);

    IF @TotalPaths = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No backup history found in msdb.';
    END
    ELSE IF @CloudCount > 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Backups stored in cloud storage (Azure Blob). Sample path: ' + (SELECT TOP 1 SamplePath FROM @BackupPaths WHERE PathType = 'Cloud');
    END
    ELSE IF @TotalPaths > 1
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Backups stored across ' + CAST(@TotalPaths AS NVARCHAR(10)) + ' distinct local/UNC paths. Paths: ' + ISNULL((SELECT STRING_AGG(SamplePath, ', ') FROM @BackupPaths), 'N/A');
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Backups stored on a single local path: ' + (SELECT TOP 1 SamplePath FROM @BackupPaths);
    END;
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;