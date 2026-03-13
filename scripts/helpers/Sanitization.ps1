function Show-SanitizationStrategy {
    Write-Host "- Detect orphaned database users mapped to instance logins."
    Write-Host "- Detect stored procedures, views, and functions with cross-database references."
    Write-Host "- Export unsupported object definitions to .sql files before dropping."
    Write-Host "- Emit a machine-readable report so users know exactly what was excluded."
}

function Get-DefaultSanitizationRules {
    return @(
        @{
            Name        = "OrphanedSqlUsers"
            Description = "SQL users mapped to server logins that cannot be recreated in Azure SQL Database."
        },
        @{
            Name        = "CrossDatabaseModules"
            Description = "Modules with three-part references that point at other databases."
        }
    )
}

function Get-UnsupportedObjects {
    param(
        [string]$Server,
        [string]$Database,
        [string]$User,
        [string]$Password
    )

    $result = @()

    $connection = Open-SqlConnection -Server $Server -Database $Database -User $User -Password $Password
    try {
        $userCommand = $connection.CreateCommand()
        $userCommand.CommandText = @"
SELECT name, type_desc, authentication_type_desc
FROM sys.database_principals
WHERE principal_id > 4
  AND type_desc = 'SQL_USER'
  AND authentication_type_desc = 'INSTANCE'
ORDER BY name
"@
        $userReader = $userCommand.ExecuteReader()
        while ($userReader.Read()) {
            $name = if ($userReader.IsDBNull(0)) { "" } else { $userReader.GetString(0) }
            $type = if ($userReader.IsDBNull(1)) { "" } else { $userReader.GetString(1) }
            $authenticationType = if ($userReader.IsDBNull(2)) { "" } else { $userReader.GetString(2) }
            if ($authenticationType -ne "INSTANCE") {
                continue
            }

            $result += @{
                Category = "OrphanedSqlUser"
                Schema   = "dbo"
                Name     = $name
                Type     = $type
                Reason   = "SQL user mapped to instance login is not portable to Azure SQL Database."
                Definition = "-- User [$name] could not be exported as-is. Recreate manually if needed."
            }
        }
        $userReader.Close()

        $moduleCommand = $connection.CreateCommand()
        $moduleCommand.CommandText = @"
SELECT
    OBJECT_SCHEMA_NAME(o.object_id) AS schema_name,
    o.name AS object_name,
    o.type_desc,
    m.definition
FROM sys.objects o
JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE EXISTS (
    SELECT 1
    FROM sys.sql_expression_dependencies d
    WHERE d.referencing_id = o.object_id
      AND d.referenced_database_name IS NOT NULL
      AND d.referenced_database_name <> DB_NAME()
)
   OR m.definition LIKE '%].[%].[%]%'
ORDER BY schema_name, object_name
"@
        $moduleReader = $moduleCommand.ExecuteReader()
        while ($moduleReader.Read()) {
            $schemaName = if ($moduleReader.IsDBNull(0)) { "" } else { $moduleReader.GetString(0) }
            $objectName = if ($moduleReader.IsDBNull(1)) { "" } else { $moduleReader.GetString(1) }
            $type = if ($moduleReader.IsDBNull(2)) { "" } else { $moduleReader.GetString(2) }
            $definition = if ($moduleReader.IsDBNull(3)) { "" } else { $moduleReader.GetString(3) }

            $result += @{
                Category = "CrossDatabaseModule"
                Schema   = $schemaName
                Name     = $objectName
                Type     = $type
                Reason   = "Cross-database references are not supported in Azure SQL Database bacpac import."
                Definition = $definition
            }
        }
        $moduleReader.Close()
    }
    finally {
        $connection.Close()
    }

    return $result
}

function Export-UnsupportedObjects {
    param(
        [object[]]$UnsupportedObjects,
        [string]$ArtifactsDirectory
    )

    $dir = Join-Path $ArtifactsDirectory "unsupported-objects"
    Initialize-ArtifactsDirectory -Path $dir

    foreach ($object in $UnsupportedObjects) {
        $schema = if ([string]::IsNullOrWhiteSpace($object.Schema)) { "dbo" } else { $object.Schema }
        $fileName = "{0}.{1}.{2}.sql" -f $object.Category, $schema, $object.Name
        $safeFileName = $fileName -replace '[^A-Za-z0-9._-]', '_'
        $path = Join-Path $dir $safeFileName

        $content = @(
            "-- Category: $($object.Category)"
            "-- Reason: $($object.Reason)"
            "-- Object: [$schema].[$($object.Name)]"
            ""
            $object.Definition
        ) -join [Environment]::NewLine

        Set-Content -Path $path -Value $content -Encoding UTF8
    }

    $reportPath = Join-Path $ArtifactsDirectory "sanitization-report.json"
    $UnsupportedObjects | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding UTF8
    return $reportPath
}

function Remove-UnsupportedObjects {
    param(
        [object[]]$UnsupportedObjects,
        [string]$Server,
        [string]$Database,
        [string]$User,
        [string]$Password
    )

    if (-not $UnsupportedObjects -or $UnsupportedObjects.Count -eq 0) {
        return
    }

    $sqlStatements = foreach ($object in $UnsupportedObjects) {
        switch ($object.Category) {
            "OrphanedSqlUser" {
                "IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$($object.Name.Replace("'", "''"))') DROP USER [$($object.Name.Replace("]", "]]"))];"
            }
            "CrossDatabaseModule" {
                $schema = $object.Schema.Replace("]", "]]")
                $name = $object.Name.Replace("]", "]]")
                switch ($object.Type) {
                    "SQL_STORED_PROCEDURE" {
                        "IF OBJECT_ID(N'[$schema].[$name]', 'P') IS NOT NULL DROP PROCEDURE [$schema].[$name];"
                    }
                    "VIEW" {
                        "IF OBJECT_ID(N'[$schema].[$name]', 'V') IS NOT NULL DROP VIEW [$schema].[$name];"
                    }
                    "SQL_SCALAR_FUNCTION" {
                        "IF OBJECT_ID(N'[$schema].[$name]', 'FN') IS NOT NULL DROP FUNCTION [$schema].[$name];"
                    }
                    "SQL_INLINE_TABLE_VALUED_FUNCTION" {
                        "IF OBJECT_ID(N'[$schema].[$name]', 'IF') IS NOT NULL DROP FUNCTION [$schema].[$name];"
                    }
                    "SQL_TABLE_VALUED_FUNCTION" {
                        "IF OBJECT_ID(N'[$schema].[$name]', 'TF') IS NOT NULL DROP FUNCTION [$schema].[$name];"
                    }
                    default {
                        throw "Unsupported cross-database module type '$($object.Type)' for [$schema].[$name]."
                    }
                }
            }
        }
    }

    $sql = @"
USE [$Database];
$(($sqlStatements -join [Environment]::NewLine))
"@

    Invoke-SqlNonQuery -Server $Server -Database "master" -User $User -Password $Password -Sql $sql
}
