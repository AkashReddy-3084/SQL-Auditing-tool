-- Checklist: Technical metadata (schema) captured and current
-- Scope: DATABASE
-- Scoring: 2 = user metadata objects are documented and recent changes are visible; 1 = partial metadata evidence; 0 = no user objects or metadata unavailable
-- NOTE: Automated evidence only; metadata capture process and freshness requirements require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Technical metadata could not be evaluated';
DECLARE @RecentlyModified INT = 0;
DECLARE @ObjectsTotal INT = 0;
DECLARE @DocumentedObjects INT = 0;
DECLARE @CatalogViews INT = 0;

BEGIN TRY
    SELECT @RecentlyModified = COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND modify_date > DATEADD(day, -180, GETDATE());
    SELECT @ObjectsTotal = COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0;
    SELECT @DocumentedObjects = COUNT(DISTINCT major_id) FROM sys.extended_properties WHERE class = 1;
    SELECT @CatalogViews = COUNT(*) FROM sys.views WHERE is_ms_shipped = 0 AND name LIKE '%catalog%';
    SET @Score = CASE WHEN @ObjectsTotal = 0 THEN 0 WHEN @DocumentedObjects > 0 AND @RecentlyModified > 0 THEN 2 WHEN @RecentlyModified > 0 OR @CatalogViews > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'recently_modified=' + CONVERT(NVARCHAR(20), @RecentlyModified) + N', objects_total=' + CONVERT(NVARCHAR(20), @ObjectsTotal) + N', documented_objects=' + CONVERT(NVARCHAR(20), @DocumentedObjects) + N', catalog_views=' + CONVERT(NVARCHAR(20), @CatalogViews);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read technical metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;