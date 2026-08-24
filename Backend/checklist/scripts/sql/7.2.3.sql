-- Checklist: Audit trail for changes to financial-relevant data
-- Scope: DATABASE
-- Scoring: 3 = 75%+ of financial-named tables are covered by temporal versioning or a data-audit specification; 2 = 25-74%; 1 = under 25%; 0 = no financial-named tables found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @FinancialTableCount INT, @AuditedTableCount INT;

    SELECT @FinancialTableCount = COUNT(*)
    FROM sys.tables t
    WHERE t.name LIKE '%amount%' OR t.name LIKE '%price%' OR t.name LIKE '%cost%' OR t.name LIKE '%revenue%' OR t.name LIKE '%payment%' OR t.name LIKE '%invoice%' OR t.name LIKE '%transaction%';

    SELECT @AuditedTableCount = COUNT(DISTINCT t.object_id)
    FROM sys.tables t
    WHERE (t.name LIKE '%amount%' OR t.name LIKE '%price%' OR t.name LIKE '%cost%' OR t.name LIKE '%revenue%' OR t.name LIKE '%payment%' OR t.name LIKE '%invoice%' OR t.name LIKE '%transaction%')
      AND (
           t.temporal_type = 2
        OR EXISTS (
             SELECT 1 FROM sys.database_audit_specification_details asd
             WHERE asd.major_id = t.object_id AND asd.audit_action_name LIKE '%DATA%'
           )
      );

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@FinancialTableCount,0) = 0 THEN 0
             WHEN (CAST(ISNULL(@AuditedTableCount,0) AS DECIMAL(9,4)) / NULLIF(@FinancialTableCount,0)) >= 0.75 THEN 3
             WHEN (CAST(ISNULL(@AuditedTableCount,0) AS DECIMAL(9,4)) / NULLIF(@FinancialTableCount,0)) >= 0.25 THEN 2
             ELSE 1 END,
        CONCAT('Financial-named tables = ', ISNULL(@FinancialTableCount,0), ', with an audit trail mechanism (temporal or audit spec) = ', ISNULL(@AuditedTableCount,0))
    );
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'DECLARE @ft INT, @at INT;
SELECT @ft = COUNT(*)
FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
WHERE t.name LIKE ''%amount%'' OR t.name LIKE ''%price%'' OR t.name LIKE ''%cost%'' OR t.name LIKE ''%revenue%'' OR t.name LIKE ''%payment%'' OR t.name LIKE ''%invoice%'' OR t.name LIKE ''%transaction%'';
SELECT @at = COUNT(DISTINCT t.object_id)
FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
WHERE (t.name LIKE ''%amount%'' OR t.name LIKE ''%price%'' OR t.name LIKE ''%cost%'' OR t.name LIKE ''%revenue%'' OR t.name LIKE ''%payment%'' OR t.name LIKE ''%invoice%'' OR t.name LIKE ''%transaction%'')
  AND (
       t.temporal_type = 2
    OR EXISTS (
         SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.database_audit_specification_details asd
         WHERE asd.major_id = t.object_id AND asd.audit_action_name LIKE ''%DATA%''
       )
  );
SELECT @p_Db,
       CASE WHEN ISNULL(@ft,0) = 0 THEN 0
            WHEN (CAST(ISNULL(@at,0) AS DECIMAL(9,4)) / NULLIF(@ft,0)) >= 0.75 THEN 3
            WHEN (CAST(ISNULL(@at,0) AS DECIMAL(9,4)) / NULLIF(@ft,0)) >= 0.25 THEN 2
            ELSE 1 END,
       CONCAT(''Financial-named tables = '', ISNULL(@ft,0), '', with an audit trail mechanism (temporal or audit spec) = '', ISNULL(@at,0));';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, CONCAT('Evaluation failed: ', ERROR_MESSAGE()));
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName) + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;