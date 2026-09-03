-- Checklist: Single source of truth - no duplicate warehouses serving the same purpose
-- Scope: DATABASE
-- Scoring: 3 = no duplicated or copy-named user tables; 2 = under 5% of user tables duplicated; 1 = under 25%; 0 = 25% or more, or no user table to inspect

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Table metadata in the current database could not be inspected';
DECLARE @Total INT = 0;
DECLARE @Suspect INT = 0;
DECLARE @Pct DECIMAL(9, 2) = 0;
DECLARE @CrossSchema NVARCHAR(MAX) = N'none';
DECLARE @CopyNamed NVARCHAR(MAX) = N'none';

CREATE TABLE #Suspect (FullName NVARCHAR(300) NOT NULL, Reason NVARCHAR(20) NOT NULL);

BEGIN TRY
    SELECT @Total = COUNT(*) FROM sys.tables AS t WHERE t.is_ms_shipped = 0;

    -- the same table name materialised in more than one schema: two stores of the same subject
    INSERT INTO #Suspect (FullName, Reason)
    SELECT CONCAT(s.name, N'.', t.name), N'cross-schema'
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND EXISTS (SELECT 1 FROM sys.tables AS d
                  WHERE d.is_ms_shipped = 0 AND d.name = t.name AND d.schema_id <> t.schema_id);

    -- forked copies of a warehouse table kept alongside the original
    INSERT INTO #Suspect (FullName, Reason)
    SELECT CONCAT(s.name, N'.', t.name), N'copy-named'
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND (t.name LIKE N'%[_]old' OR t.name LIKE N'%[_]bak' OR t.name LIKE N'%[_]backup'
           OR t.name LIKE N'%[_]copy' OR t.name LIKE N'%[_]new' OR t.name LIKE N'%[_]tmp'
           OR t.name LIKE N'%[_]temp' OR t.name LIKE N'%[_]v[0-9]' OR t.name LIKE N'%[_]dup'
           OR t.name LIKE N'%[_][0-9]')
      AND NOT EXISTS (SELECT 1 FROM #Suspect AS x WHERE x.FullName = CONCAT(s.name, N'.', t.name));

    SELECT @Suspect = COUNT(*) FROM #Suspect;
    SET @Pct = ISNULL(100.0 * @Suspect / NULLIF(CONVERT(DECIMAL(18, 4), @Total), 0), 0);

    SELECT @CrossSchema = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), FullName), N', '), 400), N'none')
    FROM #Suspect WHERE Reason = N'cross-schema';
    SELECT @CopyNamed = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), FullName), N', '), 400), N'none')
    FROM #Suspect WHERE Reason = N'copy-named';

    SET @Score = CASE
        WHEN @Total = 0 THEN 0
        WHEN @Suspect = 0 THEN 3
        WHEN @Pct < 5 THEN 2
        WHEN @Pct < 25 THEN 1
        ELSE 0 END;

    SET @Finding = CASE
        WHEN @Total = 0 THEN CONCAT(N'No user table exists in ', DB_NAME(), N', so no duplicate store could be identified')
        WHEN @Suspect = 0 THEN CONCAT(N'No duplicated or copy-named table among ', @Total, N' user tables')
        ELSE CONCAT(@Suspect, N' of ', @Total, N' user tables (', @Pct,
             N'%) look like duplicate stores; same name in several schemas: ', @CrossSchema,
             N'; copy-named tables: ', @CopyNamed) END;
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read table metadata: ' + ERROR_MESSAGE();
END CATCH;

DROP TABLE #Suspect;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
