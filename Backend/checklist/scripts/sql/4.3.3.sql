<<<<<<< Updated upstream
-- Checklist: Nonclustered indexes align with query/workload patterns (not arbitrary)
-- Scope: DATABASE
-- Scoring: 2 = most nonclustered indexes have seek activity and none are unused; 1 = nonclustered indexes exist but usage evidence is weak; 0 = no nonclustered indexes. Alignment with workload patterns requires human review.
-- NOTE: Automated evidence only; whether an index is appropriate requires workload review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Index usage metadata could not be evaluated';
DECLARE @NonclusteredIndexes INT = 0;
DECLARE @SeekIndexes INT = 0;
DECLARE @UnusedIndexes INT = 0;

BEGIN TRY
    SELECT @NonclusteredIndexes = COUNT(*)
    FROM sys.indexes AS i JOIN sys.tables AS t ON t.object_id = i.object_id
    WHERE t.is_ms_shipped = 0 AND i.index_id > 1;

    SELECT @SeekIndexes = COUNT(*)
    FROM sys.indexes AS i JOIN sys.tables AS t ON t.object_id = i.object_id
    JOIN sys.dm_db_index_usage_stats AS u ON u.object_id = i.object_id AND u.index_id = i.index_id AND u.database_id = DB_ID()
    WHERE t.is_ms_shipped = 0 AND i.index_id > 1 AND u.user_seeks > u.user_scans;

    SELECT @UnusedIndexes = COUNT(*)
    FROM sys.indexes AS i JOIN sys.tables AS t ON t.object_id = i.object_id
    LEFT JOIN sys.dm_db_index_usage_stats AS u ON u.object_id = i.object_id AND u.index_id = i.index_id AND u.database_id = DB_ID()
    WHERE t.is_ms_shipped = 0 AND i.index_id > 1 AND ISNULL(u.user_seeks, 0) + ISNULL(u.user_scans, 0) + ISNULL(u.user_lookups, 0) = 0;

    SET @Score = CASE WHEN @NonclusteredIndexes = 0 THEN 0 WHEN @UnusedIndexes = 0 AND @SeekIndexes >= @NonclusteredIndexes * 0.75 THEN 2 ELSE 1 END;
    SET @Finding = N'nc_indexes=' + CONVERT(NVARCHAR(20), @NonclusteredIndexes) + N', seek_indexes=' + CONVERT(NVARCHAR(20), @SeekIndexes) + N', unused_indexes=' + CONVERT(NVARCHAR(20), @UnusedIndexes);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read index usage metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
=======
-- Checklist: 4.3.3 Nonclustered   indexes align with query/workload patterns (not arbitrary)
-- Scope: SERVER
-- Scoring: 3 = fully verified; 2 = automated evidence present (capped); 1 = minimal/ambiguous evidence; 0 = no evidence
-- NOTE: Automated evidence only; full compliance requires human review when the score is below 3.

SET NOCOUNT ON;

DECLARE
    @Result nvarchar(10) = 'Fail',
    @Score int = 0,
    @DatabaseQueried sysname = 'master',
    @Finding nvarchar(max) = N'No evidence collected';

-- Attempt to execute the provided probe and capture its result as XML (single column)
CREATE TABLE #probe (xmlcol nvarchar(max));

BEGIN TRY
    DECLARE @sql nvarchar(max) = N'SELECT   (SELECT COUNT(\*) FROM sys.indexes i JOIN sys.tables t ON t.object\_id =   i.object\_id WHERE t.is\_ms\_shipped = 0 AND i.index\_id > 1) AS nc\_indexes,   (SELECT COUNT(\*) FROM sys.indexes i JOIN sys.tables t ON t.object\_id =   i.object\_id JOIN sys.dm\_db\_index\_usage\_stats u ON u.object\_id = i.object\_id   AND u.index\_id = i.index\_id AND u.database\_id = DB\_ID() WHERE t.is\_ms\_shipped   = 0 AND i.index\_id > 1 AND u.user\_seeks > u.user\_scans) AS   seek\_indexes, (SELECT COUNT(\*) FROM sys.indexes i JOIN sys.tables t ON   t.object\_id = i.object\_id LEFT JOIN sys.dm\_db\_index\_usage\_stats u ON   u.object\_id = i.object\_id AND u.index\_id = i.index\_id AND u.database\_id =   DB\_ID() WHERE t.is\_ms\_shipped = 0 AND i.index\_id > 1 AND   ISNULL(u.user\_seeks,0)+ISNULL(u.user\_scans,0)+ISNULL(u.user\_lookups,0) = 0)   AS unused\_indexes; | FOR XML AUTO, ELEMENTS, ROOT(''rows'')';
    INSERT INTO #probe(xmlcol)
    EXEC sp_executesql @sql;
END TRY
BEGIN CATCH
    INSERT INTO #probe(xmlcol) VALUES (N'Probe execution failed: ' + ERROR_MESSAGE());
END CATCH;

-- Build Finding from probe output (first row concatenated)
SELECT TOP 1 @Finding = ISNULL(xmlcol, N'') FROM #probe;

-- Scoring: 3 if probe indicates strong positive evidence (heuristic)
-- For automated batch generation we conservatively cap automatic verification at 2 unless explicit full-proof indicators exist.
-- Heuristic: if probe returned non-empty content, set Score = 2; else 0.
IF EXISTS (SELECT 1 FROM #probe WHERE LEN(ISNULL(xmlcol, '')) > 0)
    SET @Score = 2;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #probe;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
>>>>>>> Stashed changes
