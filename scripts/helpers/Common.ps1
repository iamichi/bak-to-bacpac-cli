function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "== $Title =="
}

function Write-Step {
    param([string]$Message)
    Write-Host "-> $Message"
}

function Assert-ToolExists {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found in PATH."
    }
}

function Initialize-SqlPackageRuntimeEnvironment {
    param()

    $userRuntimeRoot = Join-Path $HOME ".dotnet-sqlpackage"
    $userRuntimeDotnet = Join-Path $userRuntimeRoot "dotnet"

    if (-not (Test-Path -LiteralPath $userRuntimeDotnet)) {
        return
    }

    $env:DOTNET_ROOT = $userRuntimeRoot

    $pathEntries = @($env:PATH -split [IO.Path]::PathSeparator)
    if ($pathEntries -notcontains $userRuntimeRoot) {
        $env:PATH = "$userRuntimeRoot$([IO.Path]::PathSeparator)$($env:PATH)"
    }
}

function Assert-SqlPackageRunnable {
    param([string]$SqlPackagePath)

    Assert-ToolExists -Name $SqlPackagePath

    $output = & $SqlPackagePath /Version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Initialize-SqlPackageRuntimeEnvironment
        $output = & $SqlPackagePath /Version 2>&1 | Out-String
    }

    if ($LASTEXITCODE -ne 0) {
        if ($output -match "You must install or update \.NET") {
            throw "SqlPackage was found but cannot run because the required .NET runtime is missing. Install the runtime requested by SqlPackage or set DOTNET_ROOT to a compatible runtime location."
        }

        throw "SqlPackage was found but failed to run: $($output.Trim())"
    }
}

function Resolve-RelativePath {
    param(
        [string]$BasePath,
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Initialize-ArtifactsDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory | Out-Null
    }
}

function Initialize-RunDirectories {
    param([string]$ArtifactsDirectory)

    foreach ($dir in @(
        $ArtifactsDirectory,
        (Join-Path $ArtifactsDirectory "state"),
        (Join-Path $ArtifactsDirectory "unsupported-objects"),
        (Join-Path $ArtifactsDirectory "logs")
    )) {
        Initialize-ArtifactsDirectory -Path $dir
    }
}

function New-LowercaseSuffix {
    param([int]$Length = 6)

    $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $result = for ($i = 0; $i -lt $Length; $i++) {
        $chars[$bytes[$i] % $chars.Length]
    }
    return (-join $result)
}

function New-StrongPassword {
    param([int]$Length = 20)

    $chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%+="
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $result = for ($i = 0; $i -lt $Length; $i++) {
        $chars[$bytes[$i] % $chars.Length]
    }
    return (-join $result)
}

function Get-DefaultNames {
    param([string]$BakPath)

    $suffix = New-LowercaseSuffix
    $base = if ([string]::IsNullOrWhiteSpace($BakPath)) { "bak" } else { [System.IO.Path]::GetFileNameWithoutExtension($BakPath).ToLowerInvariant() }
    if ($base.Length -gt 10) { $base = $base.Substring(0, 10) }
    $base = ($base -replace '[^a-z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($base)) { $base = "bak" }

    return @{
        StorageAccountName    = ("b2bc{0}{1}" -f $base, $suffix).Substring(0, [Math]::Min(22, ("b2bc{0}{1}" -f $base, $suffix).Length))
        StorageShareName      = ("bak{0}" -f $suffix).Substring(0, [Math]::Min(20, ("bak{0}" -f $suffix).Length))
        ContainerRegistryName = ("b2bc{0}{1}" -f $base, $suffix).Substring(0, [Math]::Min(40, ("b2bc{0}{1}" -f $base, $suffix).Length))
        ContainerGroupName    = ("b2bc-{0}-{1}" -f $base, $suffix).Substring(0, [Math]::Min(50, ("b2bc-{0}-{1}" -f $base, $suffix).Length))
    }
}

function Should-UseInteractiveMode {
    param([hashtable]$Config)

    if ($Config.Interactive) {
        return $true
    }

    if ($Config.Mode -eq "plan") {
        return $false
    }

    if ([Console]::IsInputRedirected) {
        return $false
    }

    $required = switch ($Config.Mode) {
        "full" {
            @("BakPath", "AzureSqlServerFqdn", "AzureSqlDatabaseName", "SqlAdminUser", "AzureResourceGroupName")
            break
        }
        "restore-only" {
            @("BakPath", "AzureResourceGroupName")
            break
        }
        "import-only" {
            @("BacpacPath", "AzureSqlServerFqdn", "AzureSqlDatabaseName", "SqlAdminUser")
            break
        }
        "sanitize-only" {
            @("TempSqlServer", "RestoredDatabaseName")
            break
        }
        "export-only" {
            @("TempSqlServer", "RestoredDatabaseName")
            break
        }
        default {
            @()
        }
    }

    foreach ($key in $required) {
        if ([string]::IsNullOrWhiteSpace($Config[$key])) {
            return $true
        }
    }

    return $false
}

function Read-SecretValue {
    param([string]$Prompt)

    $secure = Read-Host -AsSecureString $Prompt
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Read-InteractiveConfiguration {
    param([hashtable]$Config)

    $clone = @{}
    foreach ($entry in $Config.GetEnumerator()) {
        $clone[$entry.Key] = $entry.Value
    }

    if ($clone.Mode -in @("full", "restore-only") -and [string]::IsNullOrWhiteSpace($clone.BakPath)) {
        $clone.BakPath = Read-Host "Backup file path (.bak)"
    }

    $defaults = Get-DefaultNames -BakPath $clone.BakPath
    foreach ($name in $defaults.Keys) {
        if ([string]::IsNullOrWhiteSpace($clone[$name])) {
            $clone[$name] = $defaults[$name]
        }
    }

    if ($clone.Mode -in @("full", "import-only") -and [string]::IsNullOrWhiteSpace($clone.AzureSqlServerFqdn)) {
        $clone.AzureSqlServerFqdn = Read-Host "Azure SQL server FQDN"
    }

    if ($clone.Mode -in @("full", "import-only") -and [string]::IsNullOrWhiteSpace($clone.AzureSqlDatabaseName)) {
        $clone.AzureSqlDatabaseName = Read-Host "Azure SQL database name"
    }

    if ($clone.Mode -in @("full", "import-only") -and [string]::IsNullOrWhiteSpace($clone.SqlAdminUser)) {
        $clone.SqlAdminUser = Read-Host "SQL admin user"
    }

    if ($clone.Mode -in @("full", "import-only") -and -not $clone.SqlAdminPasswordSet) {
        $clone.SqlAdminPassword = Read-SecretValue -Prompt "SQL admin password"
        $clone.SqlAdminPasswordSet = $true
    }

    if (($clone.Mode -in @("full", "restore-only")) -or $clone.AllowTargetDatabaseDeleteFallback) {
        if ([string]::IsNullOrWhiteSpace($clone.AzureResourceGroupName)) {
            $clone.AzureResourceGroupName = Read-Host "Azure resource group name"
        }
    }

    if ($clone.Mode -in @("full", "restore-only")) {
        $locationPromptDefault = if ([string]::IsNullOrWhiteSpace($clone.AzureLocation)) { "uksouth" } else { $clone.AzureLocation }
        $locationResponse = Read-Host "Azure location [$locationPromptDefault]"
        if ([string]::IsNullOrWhiteSpace($locationResponse)) {
            $clone.AzureLocation = $locationPromptDefault
        }
        else {
            $clone.AzureLocation = $locationResponse
        }
    }

    if ($clone.Mode -eq "import-only" -and [string]::IsNullOrWhiteSpace($clone.BacpacPath)) {
        $clone.BacpacPath = Read-Host "Bacpac file path (.bacpac)"
    }

    if ($clone.Mode -in @("sanitize-only", "export-only")) {
        if ([string]::IsNullOrWhiteSpace($clone.TempSqlServer)) {
            $clone.TempSqlServer = Read-Host "Temporary SQL Server host,port"
        }

        if ([string]::IsNullOrWhiteSpace($clone.RestoredDatabaseName)) {
            $clone.RestoredDatabaseName = Read-Host "Restored database name"
        }

        if (-not $clone.ContainerSaPasswordSet) {
            $clone.ContainerSaPassword = Read-SecretValue -Prompt "Temporary SQL sa password"
            $clone.ContainerSaPasswordSet = $true
        }
    }

    if ($clone.Mode -in @("restore-only", "full")) {
        if ([string]::IsNullOrWhiteSpace($clone.StorageAccountName)) {
            $clone.StorageAccountName = Read-Host "Storage account name [$($defaults.StorageAccountName)]"
            if ([string]::IsNullOrWhiteSpace($clone.StorageAccountName)) {
                $clone.StorageAccountName = $defaults.StorageAccountName
            }
        }

        if ([string]::IsNullOrWhiteSpace($clone.StorageShareName)) {
            $clone.StorageShareName = Read-Host "Storage share name [$($defaults.StorageShareName)]"
            if ([string]::IsNullOrWhiteSpace($clone.StorageShareName)) {
                $clone.StorageShareName = $defaults.StorageShareName
            }
        }

        if ([string]::IsNullOrWhiteSpace($clone.ContainerRegistryName)) {
            $clone.ContainerRegistryName = Read-Host "Container registry name [$($defaults.ContainerRegistryName)]"
            if ([string]::IsNullOrWhiteSpace($clone.ContainerRegistryName)) {
                $clone.ContainerRegistryName = $defaults.ContainerRegistryName
            }
        }

        if ([string]::IsNullOrWhiteSpace($clone.ContainerGroupName)) {
            $clone.ContainerGroupName = Read-Host "Container group name [$($defaults.ContainerGroupName)]"
            if ([string]::IsNullOrWhiteSpace($clone.ContainerGroupName)) {
                $clone.ContainerGroupName = $defaults.ContainerGroupName
            }
        }
    }

    if ($clone.Mode -in @("full", "restore-only") -and -not $clone.ContainerSaPasswordSet) {
        $clone.ContainerSaPassword = New-StrongPassword
        $clone.ContainerSaPasswordSet = $true
    }

    if (-not $clone.Contains("ReportOnly")) {
        $clone.ReportOnly = $true
    }

    if (-not $clone.Contains("ForceDropUnsupportedObjects")) {
        $clone.ForceDropUnsupportedObjects = $false
    }

    if (-not $clone.Contains("AllowTargetDatabaseDeleteFallback")) {
        $clone.AllowTargetDatabaseDeleteFallback = $false
    }

    if ($clone.Mode -in @("full", "sanitize-only") -and -not $clone.SkipSanitization) {
        $drop = Read-Host "If unsupported objects are found, drop them from the temporary restored source and continue? [y/N]"
        if ($drop -match '^(y|yes)$') {
            $clone.ReportOnly = $false
            $clone.ForceDropUnsupportedObjects = $true
        }
        else {
            $clone.ReportOnly = $true
            $clone.ForceDropUnsupportedObjects = $false
        }
    }

    if ($clone.Mode -in @("full", "restore-only")) {
        $keep = Read-Host "Keep temporary Azure resources after completion? [y/N]"
        $clone.KeepTemporaryAzureResources = $keep -match '^(y|yes)$'
    }

    if ($clone.Mode -in @("full", "import-only")) {
        $fallback = Read-Host "Allow deleting the target Azure SQL database if import fallback is required? [y/N]"
        $clone.AllowTargetDatabaseDeleteFallback = $fallback -match '^(y|yes)$'
    }

    return $clone
}

function Show-ExecutionPlan {
    param([hashtable]$Config)

    $steps = @(
        "Validate prerequisites and Azure login state",
        "Build or fetch the restore-only SQL Server container image",
        "Stage the .bak into Azure Files",
        "Create a temporary Azure Container Instance and restore the backup",
        "Detect Azure SQL incompatible objects in the restored source",
        "Export unsupported object definitions to artifacts",
        "Drop incompatible objects from the temporary source when approved",
        "Export a .bacpac using host SqlPackage",
        "Import the .bacpac into Azure SQL Database",
        "Clean up temporary Azure resources"
    )

    Write-Host "Mode: $($Config.Mode)"
    Write-Host "Artifacts: $($Config.ArtifactsDirectory)"
    Write-Host ""
    $steps | ForEach-Object { Write-Host "- $_" }
}

function Show-ConfigurationSummary {
    param([hashtable]$Config)

    Write-Section "Execution Summary"
    Write-Host "Source backup: $($Config.BakPath)"
    Write-Host "Target server: $($Config.AzureSqlServerFqdn)"
    Write-Host "Target database: $($Config.AzureSqlDatabaseName)"
    Write-Host "Resource group: $($Config.AzureResourceGroupName)"
    Write-Host "Location: $($Config.AzureLocation)"
    Write-Host "Storage account: $($Config.StorageAccountName)"
    Write-Host "Storage share: $($Config.StorageShareName)"
    Write-Host "ACR: $($Config.ContainerRegistryName)"
    Write-Host "ACI: $($Config.ContainerGroupName)"
    Write-Host "Report only sanitization: $($Config.ReportOnly)"
    Write-Host "Drop unsupported objects: $($Config.ForceDropUnsupportedObjects)"
    Write-Host "Keep temporary Azure resources: $($Config.KeepTemporaryAzureResources)"
    Write-Host "Allow target DB delete fallback: $($Config.AllowTargetDatabaseDeleteFallback)"
}

function Show-FinalSummary {
    param(
        [hashtable]$Config,
        [hashtable]$State
    )

    Write-Section "Migration Summary"
    Write-Host "Mode: $($Config.Mode)"
    Write-Host "Target: $($Config.AzureSqlServerFqdn) / $($Config.AzureSqlDatabaseName)"

    if ($State.ContainsKey("RestoredDatabaseName")) {
        Write-Host "Temporary restored database: $($State.RestoredDatabaseName)"
    }

    if ($State.ContainsKey("UnsupportedObjectCount")) {
        Write-Host "Unsupported objects reported: $($State.UnsupportedObjectCount)"
    }

    if ($State.ContainsKey("BacpacPath")) {
        Write-Host "Bacpac artifact: $($State.BacpacPath)"
    }

    if ($State.ContainsKey("AzureSqlTableCount")) {
        Write-Host "Azure SQL table count: $($State.AzureSqlTableCount)"
    }

    Write-Host "Temporary resources kept: $($Config.KeepTemporaryAzureResources)"
}

function Confirm-Action {
    param([string]$Prompt)

    $response = Read-Host "$Prompt [y/N]"
    return $response -match '^(y|yes)$'
}

function Assert-RequiredValue {
    param(
        [hashtable]$Config,
        [string]$Name
    )

    $value = $Config[$Name]
    if ($null -eq $value -or ([string]$value).Trim().Length -eq 0) {
        throw "Required configuration '$Name' is missing."
    }
}

function Save-RunState {
    param(
        [hashtable]$State,
        [string]$ArtifactsDirectory
    )

    $path = Join-Path (Join-Path $ArtifactsDirectory "state") "last-run.json"
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
    return $path
}

function Load-RunState {
    param([string]$ArtifactsDirectory)

    $path = Join-Path (Join-Path $ArtifactsDirectory "state") "last-run.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    return Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable
}

function Remove-StateValue {
    param(
        [hashtable]$State,
        [string]$Key
    )

    if ($State.ContainsKey($Key)) {
        [void]$State.Remove($Key)
    }
}

function Update-StateValue {
    param(
        [hashtable]$State,
        [string]$Key,
        $Value
    )

    $State[$Key] = $Value
}
