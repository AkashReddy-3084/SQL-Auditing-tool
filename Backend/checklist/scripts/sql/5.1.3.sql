-- Checklist: [DQ Framework & Governance] DQ KPIs defined: completeness, accuracy, timeliness, consistency, uniqueness, validity
-- Scope: DATABASE
-- Scoring: 3 = DQ rule/KPI objects exist and at least 5 of the 6 dimensions are named; 2 = 3 or 4 dimensions named; 1 = DQ objects exist but 2 or fewer dimensions named; 0 = no DQ KPI or rule definition objects found

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Data quality KPI definitions could not be inspected in the current database';

DECLARE @DqObjects INT = -1;
DECLARE @DimCount INT = 0;
DECLARE @ObjectList NVARCHAR(MAX) = 'none';
DECLARE @DimList NVARCHAR(MAX) = 'none';
DECLARE @Completeness INT = 0, @Accuracy INT = 0, @Timeliness INT = 0;
DECLARE @Consistency INT = 0, @Uniqueness INT = 0, @Validity INT = 0;

DECLARE @Dq TABLE (ObjectId INT PRIMARY KEY, FullName NVARCHAR(300));
DECLARE @Names TABLE (Nm NVARCHAR(300));

BEGIN TRY
    INSERT INTO @Dq (ObjectId, FullName)
    SELECT o.object_id, CONVERT(NVARCHAR(300), s.name + '.' + o.name)
    FROM sys.objects AS o
    INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF')
      AND (o.name LIKE '%data[_]quality%' OR o.name LIKE '%dataquality%'
           OR o.name LIKE 'dq[_]%' OR o.name LIKE '%[_]dq[_]%' OR o.name LIKE '%[_]dq'
           OR o.name LIKE '%quality%rule%' OR o.name LIKE '%quality%metric%'
           OR o.name LIKE '%quality%kpi%' OR o.name LIKE '%quality%dimension%'
           OR o.name LIKE '%quality%score%' OR o.name LIKE '%quality%threshold%');

    SELECT @DqObjects = COUNT(*) FROM @Dq;

    SET @ObjectList = ISNULL(LEFT((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), FullName), ', ') FROM @Dq), 700), 'none');

    INSERT INTO @Names (Nm) SELECT FullName FROM @Dq;

    INSERT INTO @Names (Nm)
    SELECT CONVERT(NVARCHAR(300), c.name)
    FROM sys.columns AS c
    WHERE c.object_id IN (SELECT ObjectId FROM @Dq);

    SELECT @Completeness = ISNULL(MAX(CASE WHEN Nm LIKE '%complete%' THEN 1 ELSE 0 END), 0),
           @Accuracy     = ISNULL(MAX(CASE WHEN Nm LIKE '%accura%' THEN 1 ELSE 0 END), 0),
           @Timeliness   = ISNULL(MAX(CASE WHEN Nm LIKE '%timeli%' OR Nm LIKE '%freshness%' THEN 1 ELSE 0 END), 0),
           @Consistency  = ISNULL(MAX(CASE WHEN Nm LIKE '%consisten%' THEN 1 ELSE 0 END), 0),
           @Uniqueness   = ISNULL(MAX(CASE WHEN Nm LIKE '%uniqu%' OR Nm LIKE '%duplicat%' THEN 1 ELSE 0 END), 0),
           @Validity     = ISNULL(MAX(CASE WHEN Nm LIKE '%validit%' OR Nm LIKE '%valid[_]%' THEN 1 ELSE 0 END), 0)
    FROM @Names;
END TRY
BEGIN CATCH
    SET @DqObjects = -1;
END CATCH;

SET @DimCount = @Completeness + @Accuracy + @Timeliness + @Consistency + @Uniqueness + @Validity;

SET @DimList = CASE WHEN @DimCount = 0 THEN 'none'
    ELSE STUFF(
         CASE WHEN @Completeness = 1 THEN ', completeness' ELSE '' END
       + CASE WHEN @Accuracy = 1 THEN ', accuracy' ELSE '' END
       + CASE WHEN @Timeliness = 1 THEN ', timeliness' ELSE '' END
       + CASE WHEN @Consistency = 1 THEN ', consistency' ELSE '' END
       + CASE WHEN @Uniqueness = 1 THEN ', uniqueness' ELSE '' END
       + CASE WHEN @Validity = 1 THEN ', validity' ELSE '' END, 1, 2, '') END;

SET @Score = CASE
    WHEN @DqObjects < 0 THEN 0
    WHEN @DqObjects = 0 THEN 0
    WHEN @DimCount >= 5 THEN 3
    WHEN @DimCount >= 3 THEN 2
    ELSE 1
END;

SET @Finding = CASE
    WHEN @DqObjects < 0
        THEN CONCAT('Catalog views in ', @DatabaseQueried, ' could not be read, so DQ KPI definitions were not inspected.')
    WHEN @DqObjects = 0
        THEN CONCAT('No data-quality rule, metric, KPI or dimension objects were found in ', @DatabaseQueried,
                    '; none of the six DQ dimensions is defined in the schema.')
    ELSE CONCAT(@DqObjects, ' data-quality object(s) found in ', @DatabaseQueried, ' (', @ObjectList,
                '); DQ dimensions named in those objects or their columns = ', @DimCount, ' of 6: ', @DimList, '.')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
