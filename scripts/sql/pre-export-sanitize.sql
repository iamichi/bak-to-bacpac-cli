/*
Pre-export sanitization ideas for Azure SQL Database compatibility.

This file is intentionally conservative. The tool should export object
definitions before dropping anything from the temporary restored source.
*/

-- Orphaned SQL users mapped to server logins.
SELECT
    name,
    type_desc,
    authentication_type_desc
FROM sys.database_principals
WHERE principal_id > 4
  AND type_desc = 'SQL_USER'
  AND authentication_type_desc = 'INSTANCE'
ORDER BY name;

-- Modules that appear to reference other databases by name.
SELECT
    OBJECT_SCHEMA_NAME(object_id) AS schema_name,
    OBJECT_NAME(object_id) AS object_name,
    type_desc
FROM sys.objects
WHERE object_id IN (
    SELECT object_id
    FROM sys.sql_modules
    WHERE definition LIKE '%].[%].[%]%'
       OR object_id IN (
            SELECT referencing_id
            FROM sys.sql_expression_dependencies
            WHERE referenced_database_name IS NOT NULL
              AND referenced_database_name <> DB_NAME()
       )
)
ORDER BY schema_name, object_name;
