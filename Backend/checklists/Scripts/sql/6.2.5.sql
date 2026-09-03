-- Checklist: Row-Level Security implemented where multi-tenant/segmented access is required
-- Scope: DATABASE
-- Scoring: 3 = no tenant/segment key columns exist, or every such table is covered by an enabled security policy; 2 = under 25% of those tables are uncovered; 1 = 25% or more are uncovered while an enabled policy exists; 0 = tenant/segment key columns exist with no enabled security policy, or metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Row-Level Security metadata was not readable in this database';
DECLARE @Policies INT = 0;
DECLARE @Enabled INT = 0;
DECLARE @Predicates INT = 0;
DECLARE @TenantTables INT = 0;
DECLARE @Uncovered INT = 0;
DECLARE @Names NVARCHAR(MAX) = 'none';
DECLARE @Ratio DECIMAL(9, 4) = 0;
DECLARE @Failed BIT = 0;
DECLARE @Protected TABLE (ObjectId INT PRIMARY KEY);
DECLARE @Tenant TABLE (ObjectId INT PRIMARY KEY, FullName NVARCHAR(400));

BEGIN TRY
    SELECT @Policies = COUNT(*),
           @Enabled = ISNULL(SUM(CASE WHEN is_enabled = 1 THEN 1 ELSE 0 END), 0)
    FROM sys.security_policies;

    SELECT @Predicates = COUNT(*) FROM sys.security_predicates;

    INSERT INTO @Protected (ObjectId)
    SELECT DISTINCT sp.target_object_id
    FROM sys.security_predicates AS sp
    JOIN sys.security_policies AS p ON p.object_id = sp.object_id AND p.is_enabled = 1;

    INSERT INTO @Tenant (ObjectId, FullName)
    SELECT t.object_id, CONCAT(s.name, '.', t.name)
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND EXISTS (SELECT 1
                  FROM sys.columns AS c
                  WHERE c.object_id = t.object_id
                    AND REPLACE(LOWER(c.name), '_', '') IN
                        ('tenant', 'tenantid', 'orgid', 'organizationid', 'customerid',
                         'clientid', 'ownerid', 'accountid', 'companyid', 'subscriberid'));
END TRY
BEGIN CATCH
    SET @Failed = 1;
END CATCH

SELECT @TenantTables = COUNT(*),
       @Uncovered = ISNULL(SUM(CASE WHEN g.ObjectId IS NULL THEN 1 ELSE 0 END), 0)
FROM @Tenant AS x
LEFT JOIN @Protected AS g ON g.ObjectId = x.ObjectId;

SELECT @Names = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), x.FullName), ', '), 'none')
FROM @Tenant AS x
LEFT JOIN @Protected AS g ON g.ObjectId = x.ObjectId
WHERE g.ObjectId IS NULL;

SET @Ratio = CASE WHEN @TenantTables = 0 THEN 0
                  ELSE CONVERT(DECIMAL(9, 4), @Uncovered) / NULLIF(@TenantTables, 0) END;

SET @Score = CASE
    WHEN @Failed = 1 THEN 0
    WHEN @TenantTables = 0 OR @Uncovered = 0 THEN 3
    WHEN @Enabled = 0 THEN 0
    WHEN ISNULL(@Ratio, 1) < 0.25 THEN 2
    ELSE 1 END;

SET @Finding = CASE
    WHEN @Failed = 1 THEN CONCAT('Row-Level Security metadata could not be read in ', @DatabaseQueried)
    ELSE CONCAT('security policies = ', @Policies,
                ' (enabled = ', @Enabled, '), security predicates = ', @Predicates,
                ', tables carrying a tenant/segment key column = ', @TenantTables,
                ', of those with no enabled policy = ', @Uncovered,
                CASE WHEN @Uncovered = 0 THEN '' ELSE CONCAT(' (', LEFT(@Names, 400), ')') END)
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
