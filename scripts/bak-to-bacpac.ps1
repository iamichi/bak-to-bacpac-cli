[CmdletBinding()]
param(
    [ValidateSet("plan", "status", "full", "cleanup", "sanitize-only", "restore-only", "export-only", "import-only")]
    [string]$Mode = "plan",
    [switch]$Interactive,
    [string]$BakPath,
    [string]$BacpacPath,
    [string]$TempSqlServer,
    [string]$RestoredDatabaseName,
    [string]$AzureSqlServerFqdn,
    [string]$AzureSqlDatabaseName,
    [string]$SqlAdminUser,
    [string]$SqlAdminPassword,
    [string]$AzureResourceGroupName,
    [string]$AzureLocation = "uksouth",
    [string]$StorageAccountName,
    [string]$StorageShareName = "bakconvert",
    [string]$ContainerRegistryName,
    [string]$ContainerGroupName = "bak-to-bacpac-cli",
    [string]$ContainerSaPassword,
    [string]$SqlPackagePath = "sqlpackage",
    [string]$ArtifactsDirectory = "$PSScriptRoot/../artifacts",
    [switch]$SkipSanitization,
    [switch]$KeepTemporaryAzureResources,
    [switch]$ReportOnly,
    [switch]$ForceDropUnsupportedObjects,
    [switch]$AllowTargetDatabaseDeleteFallback
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/helpers/Common.ps1"
. "$PSScriptRoot/helpers/Azure.ps1"
. "$PSScriptRoot/helpers/Sql.ps1"
. "$PSScriptRoot/helpers/Sanitization.ps1"

function Merge-StateIntoConfig {
    param(
        [hashtable]$Config,
        [hashtable]$State
    )

    if ($null -eq $State) {
        return
    }

    $mapping = @{
        BakPath                = "BakPath"
        BacpacPath             = "BacpacPath"
        TempSqlServer          = "TempSqlHost"
        RestoredDatabaseName   = "RestoredDatabaseName"
        AzureSqlServerFqdn     = "AzureSqlServerFqdn"
        AzureSqlDatabaseName   = "AzureSqlDatabaseName"
        SqlAdminUser           = "SqlAdminUser"
        AzureResourceGroupName = "AzureResourceGroupName"
        AzureLocation          = "AzureLocation"
        StorageAccountName     = "StorageAccountName"
        StorageShareName       = "StorageShareName"
        ContainerRegistryName  = "ContainerRegistryName"
        ContainerGroupName     = "ContainerGroupName"
        ContainerSaPassword    = "ContainerSaPassword"
    }

    foreach ($key in $mapping.Keys) {
        $stateKey = $mapping[$key]
        if ([string]::IsNullOrWhiteSpace([string]$Config[$key]) -and $State.ContainsKey($stateKey) -and -not [string]::IsNullOrWhiteSpace([string]$State[$stateKey])) {
            $Config[$key] = $State[$stateKey]
        }
    }

    if (-not $Config.ContainerSaPasswordSet -and -not [string]::IsNullOrWhiteSpace([string]$Config.ContainerSaPassword)) {
        $Config.ContainerSaPasswordSet = $true
    }
}

function Persist-ConfigToState {
    param(
        [hashtable]$Config,
        [hashtable]$State
    )

    $mapping = @{
        BakPath                = "BakPath"
        BacpacPath             = "BacpacPath"
        TempSqlServer          = "TempSqlHost"
        RestoredDatabaseName   = "RestoredDatabaseName"
        AzureSqlServerFqdn     = "AzureSqlServerFqdn"
        AzureSqlDatabaseName   = "AzureSqlDatabaseName"
        SqlAdminUser           = "SqlAdminUser"
        AzureResourceGroupName = "AzureResourceGroupName"
        AzureLocation          = "AzureLocation"
        StorageAccountName     = "StorageAccountName"
        StorageShareName       = "StorageShareName"
        ContainerRegistryName  = "ContainerRegistryName"
        ContainerGroupName     = "ContainerGroupName"
        ContainerSaPassword    = "ContainerSaPassword"
    }

    foreach ($key in $mapping.Keys) {
        $value = $Config[$key]
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            Update-StateValue -State $State -Key $mapping[$key] -Value $value
        }
    }

    Update-StateValue -State $State -Key "ContainerSaPasswordSet" -Value ([bool]$Config.ContainerSaPasswordSet)
}

function Save-StateSnapshot {
    param(
        [hashtable]$Config,
        [hashtable]$State
    )

    Persist-ConfigToState -Config $Config -State $State
    Save-RunState -State $State -ArtifactsDirectory $Config.ArtifactsDirectory | Out-Null
}

function Resolve-InputPaths {
    param([hashtable]$Config)

    $basePath = (Get-Location).Path
    foreach ($key in @("BakPath", "BacpacPath")) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Config[$key])) {
            $Config[$key] = Resolve-RelativePath -BasePath $basePath -Path $Config[$key]
        }
    }
}

function Resolve-ModeDefaults {
    param([hashtable]$Config)

    if (($Config.Mode -in @("full", "restore-only")) -and -not [string]::IsNullOrWhiteSpace($Config.BakPath)) {
        $defaults = Get-DefaultNames -BakPath $Config.BakPath
        foreach ($name in @("StorageAccountName", "StorageShareName", "ContainerRegistryName", "ContainerGroupName")) {
            if ([string]::IsNullOrWhiteSpace([string]$Config[$name])) {
                $Config[$name] = $defaults[$name]
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Config.RestoredDatabaseName) -and -not [string]::IsNullOrWhiteSpace($Config.BakPath)) {
        $Config.RestoredDatabaseName = [System.IO.Path]::GetFileNameWithoutExtension($Config.BakPath)
    }

    if (($Config.Mode -in @("full", "restore-only")) -and (-not $Config.ContainerSaPasswordSet -or [string]::IsNullOrWhiteSpace($Config.ContainerSaPassword))) {
        $Config.ContainerSaPassword = New-StrongPassword
        $Config.ContainerSaPasswordSet = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.ContainerSaPassword)) {
        $Config.ContainerSaPasswordSet = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.SqlAdminPassword)) {
        $Config.SqlAdminPasswordSet = $true
    }
}

function Test-ConfiguredFileExists {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    return (Test-Path -LiteralPath $Path)
}

function Get-AvailableNextModes {
    param(
        [hashtable]$Config,
        [hashtable]$State
    )

    $modes = @("plan", "status")

    if (-not [string]::IsNullOrWhiteSpace($Config.BakPath) -and -not [string]::IsNullOrWhiteSpace($Config.AzureResourceGroupName)) {
        $modes += "restore-only"
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.TempSqlServer) -and -not [string]::IsNullOrWhiteSpace($Config.RestoredDatabaseName) -and -not [string]::IsNullOrWhiteSpace($Config.ContainerSaPassword)) {
        $modes += @("sanitize-only", "export-only")
    }

    if (Test-ConfiguredFileExists -Path $Config.BacpacPath) {
        $modes += "import-only"
    }

    if ($State.Count -gt 0) {
        $modes += "cleanup"
    }

    return @($modes | Select-Object -Unique)
}

function Show-StatusReport {
    param(
        [hashtable]$Config,
        [hashtable]$State
    )

    Write-Section "Status"
    Write-Host "Artifacts directory: $($Config.ArtifactsDirectory)"

    $statePath = Join-Path (Join-Path $Config.ArtifactsDirectory "state") "last-run.json"
    if (-not (Test-Path -LiteralPath $statePath)) {
        Write-Host "Saved state: none"
        Write-Host "Next modes: plan, full"
        return
    }

    Write-Host "Saved state: $statePath"
    if ($State.ContainsKey("StartedAt")) {
        Write-Host "Started at: $($State.StartedAt)"
    }
    if ($State.ContainsKey("FinishedAt")) {
        Write-Host "Finished at: $($State.FinishedAt)"
    }

    Write-Host ""
    Write-Host "Known inputs"
    Write-Host "- Bak path: $(if ([string]::IsNullOrWhiteSpace($Config.BakPath)) { '<missing>' } else { $Config.BakPath })"
    Write-Host "- Bacpac path: $(if ([string]::IsNullOrWhiteSpace($Config.BacpacPath)) { '<missing>' } else { $Config.BacpacPath })"
    Write-Host "- Temp SQL server: $(if ([string]::IsNullOrWhiteSpace($Config.TempSqlServer)) { '<missing>' } else { $Config.TempSqlServer })"
    Write-Host "- Restored database: $(if ([string]::IsNullOrWhiteSpace($Config.RestoredDatabaseName)) { '<missing>' } else { $Config.RestoredDatabaseName })"
    Write-Host "- Azure SQL server: $(if ([string]::IsNullOrWhiteSpace($Config.AzureSqlServerFqdn)) { '<missing>' } else { $Config.AzureSqlServerFqdn })"
    Write-Host "- Azure SQL database: $(if ([string]::IsNullOrWhiteSpace($Config.AzureSqlDatabaseName)) { '<missing>' } else { $Config.AzureSqlDatabaseName })"

    Write-Host ""
    Write-Host "Secrets present"
    Write-Host "- SQL admin password set: $([bool]$Config.SqlAdminPasswordSet)"
    Write-Host "- Temp SQL sa password set: $([bool]$Config.ContainerSaPasswordSet)"

    $sanitizationReportPath = Join-Path $Config.ArtifactsDirectory "sanitization-report.json"
    $permissionReportPath = Join-Path $Config.ArtifactsDirectory "permission-report.json"
    $unsupportedObjectsDir = Join-Path $Config.ArtifactsDirectory "unsupported-objects"

    Write-Host ""
    Write-Host "Artifacts"
    Write-Host "- Permission report: $(if (Test-Path -LiteralPath $permissionReportPath) { $permissionReportPath } else { '<missing>' })"
    Write-Host "- Sanitization report: $(if (Test-Path -LiteralPath $sanitizationReportPath) { $sanitizationReportPath } else { '<missing>' })"
    Write-Host "- Unsupported object SQL count: $(if (Test-Path -LiteralPath $unsupportedObjectsDir) { @(Get-ChildItem -LiteralPath $unsupportedObjectsDir -File -Filter '*.sql' -ErrorAction SilentlyContinue).Count } else { 0 })"
    Write-Host "- Bacpac file exists: $(Test-ConfiguredFileExists -Path $Config.BacpacPath)"

    Write-Host ""
    Write-Host "Recorded progress"
    Write-Host "- Restore completed: $($State.ContainsKey('TempSqlHost') -and $State.ContainsKey('RestoredDatabaseName'))"
    Write-Host "- Sanitization scanned: $($State.ContainsKey('UnsupportedObjectCount'))"
    Write-Host "- Unsupported objects dropped: $(if ($State.ContainsKey('UnsupportedObjectsDropped')) { [bool]$State.UnsupportedObjectsDropped } else { $false })"
    Write-Host "- Bacpac exported: $(Test-ConfiguredFileExists -Path $Config.BacpacPath)"
    Write-Host "- Azure SQL verified: $($State.ContainsKey('AzureSqlTableCount'))"

    Write-Host ""
    Write-Host "Next modes: $((Get-AvailableNextModes -Config $Config -State $State) -join ', ')"
}

function Get-RequiredToolsForMode {
    param([string]$Mode, [hashtable]$Config)

    $tools = switch ($Mode) {
        "plan" { @() ; break }
        "status" { @() ; break }
        "cleanup" { @("az") ; break }
        "restore-only" { @("az", "pwsh") ; break }
        "sanitize-only" { @("pwsh") ; break }
        "export-only" { @($Config.SqlPackagePath) ; break }
        "import-only" {
            $result = @($Config.SqlPackagePath)
            if ($Config.AllowTargetDatabaseDeleteFallback -or -not [string]::IsNullOrWhiteSpace($Config.AzureResourceGroupName)) {
                $result += "az"
            }
            $result
            break
        }
        default { @("az", "pwsh", $Config.SqlPackagePath) }
    }

    return @($tools | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Assert-RequiredConfigValues {
    param(
        [hashtable]$Config,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        Assert-RequiredValue -Config $Config -Name $name
    }
}

function Assert-FileExists {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found at $Path"
    }
}

function Invoke-AzureValidation {
    param(
        [hashtable]$Config,
        [switch]$RequirePermissionCheck
    )

    Write-Section "Validation"
    Test-AzureLogin
    $accountInfo = Get-AzureAccountInfo
    Write-Host "Azure subscription: $($accountInfo.name) [$($accountInfo.id)]"

    if ($RequirePermissionCheck) {
        Test-AzureRequiredPermissions -Config $Config -AccountInfo $accountInfo
    }
}

function Invoke-RestoreStage {
    param(
        [hashtable]$Config,
        [hashtable]$State
    )

    Write-Section "Azure Resources"
    Ensure-AzureResourceGroup -Config $Config -State $State
    Save-StateSnapshot -Config $Config -State $State
    Ensure-StorageAccount -Config $Config -State $State
    Save-StateSnapshot -Config $Config -State $State
    Ensure-StorageShare -Config $Config -State $State
    Save-StateSnapshot -Config $Config -State $State
    Ensure-ContainerRegistry -Config $Config -State $State
    Save-StateSnapshot -Config $Config -State $State

    Write-Section "Build And Upload"
    Invoke-AcrBuildForRestoreImage -Config $Config
    Upload-BackupToFileShare -Config $Config

    Write-Section "Temporary Restore SQL"
    New-RestoreContainerInstance -Config $Config -State $State
    Save-StateSnapshot -Config $Config -State $State

    $container = Wait-ContainerInstanceReady -Config $Config
    $Config.TempSqlServer = "$($container.ipAddress.ip),1433"
    Update-StateValue -State $State -Key "TempSqlHost" -Value $Config.TempSqlServer
    Save-StateSnapshot -Config $Config -State $State

    Wait-TcpPort -HostName $container.ipAddress.ip -Port 1433
    Wait-TempSqlServerReady -Server $Config.TempSqlServer -User "sa" -Password $Config.ContainerSaPassword
    Wait-RestoredDatabaseReady -Server $Config.TempSqlServer -User "sa" -Password $Config.ContainerSaPassword -DatabaseName $Config.RestoredDatabaseName

    Update-StateValue -State $State -Key "RestoredDatabaseName" -Value $Config.RestoredDatabaseName
    Save-StateSnapshot -Config $Config -State $State
}

function Invoke-SanitizationStage {
    param(
        [hashtable]$Config,
        [hashtable]$State,
        [switch]$StopAfterReportOnly
    )

    Write-Section "Sanitization"
    if ($Config.SkipSanitization) {
        Write-Step "Skipping sanitization"
        return
    }

    $unsupportedObjects = @(Get-UnsupportedObjects -Server $Config.TempSqlServer -Database $Config.RestoredDatabaseName -User "sa" -Password $Config.ContainerSaPassword)
    $reportPath = Export-UnsupportedObjects -UnsupportedObjects $unsupportedObjects -ArtifactsDirectory $Config.ArtifactsDirectory
    Write-Host "Sanitization report: $reportPath"
    Write-Host "Unsupported object count: $($unsupportedObjects.Count)"
    Update-StateValue -State $State -Key "UnsupportedObjectCount" -Value $unsupportedObjects.Count
    Save-StateSnapshot -Config $Config -State $State

    if ($unsupportedObjects.Count -eq 0) {
        return
    }

    if ($Config.ReportOnly) {
        if ($StopAfterReportOnly) {
            Write-Step "Report-only mode enabled; leaving unsupported objects in the temporary restored source"
            return
        }

        throw "Unsupported objects were detected and report-only mode is enabled."
    }

    if (-not $Config.ForceDropUnsupportedObjects) {
        if (-not $Config.Interactive) {
            throw "Unsupported objects were detected. Re-run with -ForceDropUnsupportedObjects or -ReportOnly."
        }

        if (-not (Confirm-Action -Prompt "Drop unsupported objects from the temporary restored source and continue")) {
            throw "Cancelled after sanitization report."
        }
    }

    Remove-UnsupportedObjects -UnsupportedObjects $unsupportedObjects -Server $Config.TempSqlServer -Database $Config.RestoredDatabaseName -User "sa" -Password $Config.ContainerSaPassword
    Update-StateValue -State $State -Key "UnsupportedObjectsDropped" -Value $true
    Save-StateSnapshot -Config $Config -State $State
}

function Invoke-ExportStage {
    param(
        [hashtable]$Config,
        [hashtable]$State
    )

    Write-Section "Bacpac Export"
    $Config.BacpacPath = Export-BacpacFromTempSql -Config $Config -TempSqlServer $Config.TempSqlServer
    Update-StateValue -State $State -Key "BacpacPath" -Value $Config.BacpacPath
    Save-StateSnapshot -Config $Config -State $State
    Write-Host "Bacpac: $($Config.BacpacPath)"
}

function Invoke-ImportStage {
    param([hashtable]$Config)

    Write-Section "Azure SQL Import"
    try {
        Import-BacpacToAzureSql -Config $Config -BacpacPath $Config.BacpacPath
    }
    catch {
        if (-not $Config.AllowTargetDatabaseDeleteFallback) {
            throw
        }

        if (-not $Config.Interactive) {
            throw "Import failed. Target database delete fallback is disabled in non-interactive mode."
        }

        if (-not (Confirm-Action -Prompt "Import failed. Delete target Azure SQL database and retry")) {
            throw
        }

        Remove-AzureSqlDatabase -Config $Config
        Import-BacpacToAzureSql -Config $Config -BacpacPath $Config.BacpacPath
    }
}

function Invoke-VerificationStage {
    param(
        [hashtable]$Config,
        [hashtable]$State
    )

    Write-Section "Verification"
    $tableCount = Get-AzureSqlTableCount -Config $Config
    Write-Host "Azure SQL table count: $tableCount"
    Update-StateValue -State $State -Key "AzureSqlTableCount" -Value $tableCount
    Update-StateValue -State $State -Key "FinishedAt" -Value ((Get-Date).ToString("o"))
    Save-StateSnapshot -Config $Config -State $State
}

$config = @{
    Mode                           = $Mode
    Interactive                    = [bool]$Interactive
    BakPath                        = $BakPath
    BacpacPath                     = $BacpacPath
    TempSqlServer                  = $TempSqlServer
    RestoredDatabaseName           = $RestoredDatabaseName
    AzureSqlServerFqdn             = $AzureSqlServerFqdn
    AzureSqlDatabaseName           = $AzureSqlDatabaseName
    SqlAdminUser                   = $SqlAdminUser
    SqlAdminPassword               = $SqlAdminPassword
    SqlAdminPasswordSet            = -not [string]::IsNullOrWhiteSpace($SqlAdminPassword)
    AzureResourceGroupName         = $AzureResourceGroupName
    AzureLocation                  = $AzureLocation
    StorageAccountName             = $StorageAccountName
    StorageShareName               = $StorageShareName
    ContainerRegistryName          = $ContainerRegistryName
    ContainerGroupName             = $ContainerGroupName
    ContainerSaPassword            = $ContainerSaPassword
    ContainerSaPasswordSet         = -not [string]::IsNullOrWhiteSpace($ContainerSaPassword)
    SqlPackagePath                 = $SqlPackagePath
    ArtifactsDirectory             = (Resolve-RelativePath -BasePath $PSScriptRoot -Path $ArtifactsDirectory)
    SkipSanitization               = [bool]$SkipSanitization
    KeepTemporaryAzureResources    = [bool]$KeepTemporaryAzureResources
    ReportOnly                     = [bool]$ReportOnly
    ForceDropUnsupportedObjects    = [bool]$ForceDropUnsupportedObjects
    AllowTargetDatabaseDeleteFallback = [bool]$AllowTargetDatabaseDeleteFallback
}

Initialize-RunDirectories -ArtifactsDirectory $config.ArtifactsDirectory
$state = Load-RunState -ArtifactsDirectory $config.ArtifactsDirectory
if ($null -eq $state) {
    $state = @{}
}

Merge-StateIntoConfig -Config $config -State $state
Resolve-InputPaths -Config $config
Resolve-ModeDefaults -Config $config

if (Should-UseInteractiveMode -Config $config) {
    $config.Interactive = $true
    $config = Read-InteractiveConfiguration -Config $config
    Resolve-InputPaths -Config $config
    Resolve-ModeDefaults -Config $config
}

foreach ($tool in (Get-RequiredToolsForMode -Mode $Mode -Config $config)) {
    if ($tool -eq $config.SqlPackagePath) {
        Assert-SqlPackageRunnable -SqlPackagePath $tool
    }
    else {
        Assert-ToolExists -Name $tool
    }
}

if ($Mode -notin @("plan", "status")) {
    Update-StateValue -State $state -Key "StartedAt" -Value ((Get-Date).ToString("o"))
    Remove-StateValue -State $state -Key "FinishedAt"
}

Resolve-ModeDefaults -Config $config

switch ($Mode) {
    "plan" {
        Write-Section "Execution Plan"
        Show-ExecutionPlan -Config $config
        Write-Section "Sanitization Strategy"
        Show-SanitizationStrategy
        break
    }

    "status" {
        Show-StatusReport -Config $config -State $state
        break
    }

    "cleanup" {
        if ($state.Count -eq 0) {
            throw "No saved run state found for cleanup."
        }

        Merge-StateIntoConfig -Config $config -State $state
        Remove-TemporaryResources -Config $config -State $state
        break
    }

    "restore-only" {
        Assert-RequiredConfigValues -Config $config -Names @("BakPath", "AzureResourceGroupName")
        Assert-FileExists -Path $config.BakPath -Label "Backup file"
        Show-ConfigurationSummary -Config $config
        if ($config.Interactive -and -not (Confirm-Action -Prompt "Proceed with restore-only workflow")) {
            throw "Cancelled."
        }

        Save-StateSnapshot -Config $config -State $state
        Invoke-AzureValidation -Config $config -RequirePermissionCheck
        Invoke-RestoreStage -Config $config -State $state
        Show-FinalSummary -Config $config -State $state
        break
    }

    "sanitize-only" {
        Assert-RequiredConfigValues -Config $config -Names @("TempSqlServer", "RestoredDatabaseName", "ContainerSaPassword")
        Save-StateSnapshot -Config $config -State $state
        Invoke-SanitizationStage -Config $config -State $state -StopAfterReportOnly
        Show-FinalSummary -Config $config -State $state
        break
    }

    "export-only" {
        Assert-RequiredConfigValues -Config $config -Names @("TempSqlServer", "RestoredDatabaseName", "ContainerSaPassword")
        Save-StateSnapshot -Config $config -State $state
        Invoke-ExportStage -Config $config -State $state
        Show-FinalSummary -Config $config -State $state
        break
    }

    "import-only" {
        Assert-RequiredConfigValues -Config $config -Names @("BacpacPath", "AzureSqlServerFqdn", "AzureSqlDatabaseName", "SqlAdminUser")
        Assert-FileExists -Path $config.BacpacPath -Label "Bacpac file"
        if (-not $config.SqlAdminPasswordSet -or [string]::IsNullOrWhiteSpace($config.SqlAdminPassword)) {
            throw "SqlAdminPassword is required."
        }

        Show-ConfigurationSummary -Config $config
        if ($config.Interactive -and -not (Confirm-Action -Prompt "Proceed with import-only workflow")) {
            throw "Cancelled."
        }

        Save-StateSnapshot -Config $config -State $state
        if ($config.AllowTargetDatabaseDeleteFallback) {
            Assert-RequiredConfigValues -Config $config -Names @("AzureResourceGroupName")
            Invoke-AzureValidation -Config $config -RequirePermissionCheck
        }

        Invoke-ImportStage -Config $config
        Invoke-VerificationStage -Config $config -State $state
        Show-FinalSummary -Config $config -State $state
        break
    }

    default {
        Assert-RequiredConfigValues -Config $config -Names @("BakPath", "AzureSqlServerFqdn", "AzureSqlDatabaseName", "SqlAdminUser", "AzureResourceGroupName")
        Assert-FileExists -Path $config.BakPath -Label "Backup file"
        if (-not $config.SqlAdminPasswordSet -or [string]::IsNullOrWhiteSpace($config.SqlAdminPassword)) {
            throw "SqlAdminPassword is required."
        }

        Show-ConfigurationSummary -Config $config
        if ($config.Interactive -and -not (Confirm-Action -Prompt "Proceed with full migration workflow")) {
            throw "Cancelled."
        }

        Save-StateSnapshot -Config $config -State $state
        Invoke-AzureValidation -Config $config -RequirePermissionCheck

        try {
            Invoke-RestoreStage -Config $config -State $state
            Invoke-SanitizationStage -Config $config -State $state
            Invoke-ExportStage -Config $config -State $state
            Invoke-ImportStage -Config $config
            Invoke-VerificationStage -Config $config -State $state
            Show-FinalSummary -Config $config -State $state
        }
        finally {
            Remove-TemporaryResources -Config $config -State $state
        }
    }
}
