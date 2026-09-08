DECLARE @Score INT = 3;
DECLARE @Finding VARCHAR(MAX) = '';
DECLARE @DatabaseQueried VARCHAR(128) = 'master';
DECLARE @Result VARCHAR(50);

BEGIN TRY
    IF SERVERPROPERTY('EngineEdition') = 5
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Azure SQL Database: manual verification required against external change management tracker.';
    END
    ELSE
    BEGIN
        DECLARE @EnableDfltTrace INT;
        SELECT @EnableDfltTrace = CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'default trace enabled';

        IF @EnableDfltTrace = 1
        BEGIN
            DECLARE @TraceFilePath VARCHAR(256);
            SELECT @TraceFilePath = path FROM sys.traces WHERE is_default = 1;
            
            IF @TraceFilePath IS NOT NULL
            BEGIN
                DECLARE @EventCount INT = 0;
                
                DECLARE @SqlTrace NVARCHAR(MAX) = N'
                    SELECT @EvtCountOut = COUNT(*)
                    FROM fn_trace_gettable(@TracePath, DEFAULT)
                    WHERE EventClass IN (46, 47, 164)
                      AND StartTime >= DATEADD(day, -30, GETDATE())
                      AND DatabaseID > 4;';
                
                EXEC sp_executesql @SqlTrace, 
                    N'@TracePath VARCHAR(256), @EvtCountOut INT OUTPUT', 
                    @TracePath = @TraceFilePath, 
                    @EvtCountOut = @EventCount OUTPUT;
                  
                IF @EventCount > 0
                BEGIN
                    SET @Score = 1;
                    SET @Finding = CAST(@EventCount AS VARCHAR) + ' recent schema changes detected in user databases via default trace. Verify against formal change control.';
                END
                ELSE
                BEGIN
                    SET @Score = 3;
                    SET @Finding = 'No user database schema changes detected in available default trace rollover.';
                END
            END
            ELSE
            BEGIN
                SET @Score = 1;
                SET @Finding = 'Default trace is enabled but trace path could not be located.';
            END
        END
        ELSE
        BEGIN
            SET @Score = 1;
            SET @Finding = 'Default trace is not enabled. Cannot dynamically verify recent schema changes.';
        END
    END
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = 'Error verifying schema changes: ' + ERROR_MESSAGE();
END CATCH

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT 
    @Result AS Result, 
    @Score AS Score, 
    @DatabaseQueried AS DatabaseQueried, 
    @Finding AS Finding;