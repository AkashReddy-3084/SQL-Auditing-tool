DECLARE @Score INT = 0;
DECLARE @Finding VARCHAR(MAX) = '';
DECLARE @DatabaseQueried VARCHAR(128) = ISNULL(DB_NAME(), 'None');

IF @DatabaseQueried = 'None'
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    IF EXISTS (
        SELECT 1 
        FROM sys.databases 
        WHERE name = @DatabaseQueried 
          AND snapshot_isolation_state = 0 
          AND is_read_committed_snapshot_on = 0
    )
    BEGIN
        -- Non-compliant
        SET @Score = 5;
        SET @Finding = CONCAT('Database ', @DatabaseQueried, ' does not have RCSI or Snapshot Isolation enabled.');
    END
    ELSE
    BEGIN
        -- Compliant
        SET @Score = 0;
        SET @Finding = CONCAT('Database ', @DatabaseQueried, ' has RCSI or Snapshot Isolation enabled.');
    END
END

DECLARE @Result VARCHAR(50);
SET @Result = CASE 
    WHEN @Score >= 1 THEN 'Fail' 
    WHEN @DatabaseQueried = 'None' THEN 'Fail'
    ELSE 'Pass' 
END;

SELECT 
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;