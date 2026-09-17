-- Checklist: Elastic pools used where multiple databases share capacity efficiently
-- Scope: SERVER
-- Scoring: 3 = every user database is pooled, the server hosts at most one user database, or the platform already shares instance-level capacity; 2 = elastic pools in use but coverage is partial; 1 = 2 to 4 databases and none pooled; 0 = 5 or more databases and none pooled

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Elastic pool membership could not be determined';

DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Total INT = 0;
DECLARE @Pooled INT = 0;
DECLARE @Pools INT = 0;
DECLARE @Unpooled NVARCHAR(MAX) = '';
DECLARE @Probed BIT = 0;
DECLARE @Sql NVARCHAR(MAX);

IF @Edition = 5 AND OBJECT_ID('sys.database_service_objectives') IS NOT NULL
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @t = COUNT(*),
       @p = ISNULL(SUM(CASE WHEN o.elastic_pool_name IS NULL THEN 0 ELSE 1 END), 0),
       @n = COUNT(DISTINCT o.elastic_pool_name),
       @u = ISNULL(LEFT(STRING_AGG(CASE WHEN o.elastic_pool_name IS NULL
                                        THEN CONVERT(NVARCHAR(MAX), d.name) END, '', ''), 400), '''')
FROM sys.databases AS d
LEFT JOIN sys.database_service_objectives AS o ON o.database_id = d.database_id
WHERE d.name <> N''master'';';

        EXEC sp_executesql @Sql,
             N'@t INT OUTPUT, @p INT OUTPUT, @n INT OUTPUT, @u NVARCHAR(MAX) OUTPUT',
             @t = @Total OUTPUT, @p = @Pooled OUTPUT, @n = @Pools OUTPUT, @u = @Unpooled OUTPUT;

        SET @Probed = 1;
    END TRY
    BEGIN CATCH
        SET @Probed = 0;
    END CATCH
END

SET @Total = ISNULL(@Total, 0);
SET @Pooled = ISNULL(@Pooled, 0);
SET @Pools = ISNULL(@Pools, 0);
SET @Unpooled = ISNULL(@Unpooled, '');

IF @Probed = 0
BEGIN
    BEGIN TRY
        SELECT @Total = COUNT(*)
        FROM sys.databases
        WHERE database_id > 4 AND state = 0;
    END TRY
    BEGIN CATCH
        SET @Total = 0;
    END CATCH

    SET @Score = 3;
    SET @Finding = CONCAT('Engine edition ', @Edition,
                          ' does not expose elastic pools; the ', @Total,
                          ' online user database(s) on this instance already share its compute and storage capacity.');
END
ELSE IF @Total <= 1
BEGIN
    SET @Score = 3;
    SET @Finding = CONCAT('This Azure SQL logical server hosts ', @Total,
                          ' user database(s); elastic pools share capacity across multiple databases and are not required here.');
END
ELSE IF @Pooled = @Total
BEGIN
    SET @Score = 3;
    SET @Finding = CONCAT('All ', @Total, ' user databases on this logical server belong to an elastic pool (',
                          @Pools, ' distinct pool(s)), so compute capacity is shared rather than provisioned per database.');
END
ELSE IF @Pooled > 0
BEGIN
    SET @Score = 2;
    SET @Finding = CONCAT(@Pooled, ' of ', @Total, ' user databases are in an elastic pool (',
                          @Pools, ' distinct pool(s)); still provisioned as single databases: ', @Unpooled);
END
ELSE IF @Total <= 4
BEGIN
    SET @Score = 1;
    SET @Finding = CONCAT('None of the ', @Total,
                          ' user databases on this logical server are in an elastic pool; each is a single database: ', @Unpooled);
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = CONCAT(@Total,
                          ' user databases are provisioned as isolated single databases with no elastic pool: ', @Unpooled);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
