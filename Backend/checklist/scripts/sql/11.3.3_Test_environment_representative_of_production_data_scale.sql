-- Checklist: Test environment representative of production (data, scale)
-- Scope: DATABASE
-- Scoring: 0: Negligible data (<1k rows or <100MB). 1: Limited data (1k-100k rows or 100MB-1GB). 2: Substantial data (100k-10M rows or 1GB-100GB). 3: Large-scale data (>10M rows or >100GB). NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @TotalRows BIGINT = 0;
DECLARE @TotalSizeMB DECIMAL(18,2) = 0;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbRows BIGINT,
    DbSizeMB DECIMAL(18,2),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'DECLARE @Rows BIGINT;
    DECLARE @SizeMB DECIMAL(18,2);
    SELECT @Rows = SUM(row_count) FROM sys.dm_db_partition_stats WHERE index_id < 2;
    SELECT @SizeMB = SUM(size * 8.0 / 1024) FROM sys.database_files;
    INSERT INTO #DbResults (DbName, DbRows, DbSizeMB, DbScore, Finding)
    VALUES (''' + @DbName + ''', @Rows, @SizeMB, 0, CAST(@Rows AS NVARCHAR) + '' rows, '' + CAST(@SizeMB AS NVARCHAR) + '' MB);';
    EXEC sp_executesql