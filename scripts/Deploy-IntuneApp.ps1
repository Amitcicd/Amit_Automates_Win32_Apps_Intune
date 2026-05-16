Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "--- 0. Bootstrap ---"

$requiredEnv = @("APP_NAME","APP_VERSION","INSTALL_CMD","UNINSTALL_CMD","INTUNEWIN_PATH")
foreach ($v in $requiredEnv) {
    if ([string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($v))) {
        Write-Error "Missing required environment variable: $v"
        exit 1
    }
}

$appName      = $env:APP_NAME
$appVersion   = $env:APP_VERSION
$publisher    = if ($env:APP_PUBLISHER) { $env:APP_PUBLISHER } else { "Unknown" }
$description  = if ($env:APP_DESC)      { $env:APP_DESC }      else { $appName }
$installCmd   = $env:INSTALL_CMD
$uninstallCmd = $env:UNINSTALL_CMD
$pkgPath      = $env:INTUNEWIN_PATH
$forceUpdate  = $env:FORCE_UPDATE -eq "true"

if (-not (Test-Path $pkgPath)) {
    Write-Error "Package not found: $pkgPath"
    exit 1
}

Write-Host "App Name    : $appName"
Write-Host "App Version : $appVersion"
Write-Host "Package     : $pkgPath ($([math]::Round((Get-Item $pkgPath).Length/1MB,2)) MB)"
Write-Host "Force Update: $forceUpdate"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Pin to 1.2.1 which uses global auth header
if (-not (Get-Module -ListAvailable -Name IntuneWin32App | Where-Object Version -eq "1.2.1")) {
    Write-Host "Installing IntuneWin32App 1.2.1"
    Install-Module -Name IntuneWin32App -RequiredVersion 1.2.1 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
}
Import-Module IntuneWin32App -RequiredVersion 1.2.1 -Force

Write-Host "--- 1. Authenticate (OIDC) ---"

try {
    $tokenObj = Get-AzAccessToken -ResourceTypeName MSGraph -AsSecureString -ErrorAction Stop
    Write-Host "Got MSGraph access token via OIDC"
}
catch {
    Write-Error "Failed to get MSGraph token: $_"
    exit 1
}

$plainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
)

# Set global auth header — required by IntuneWin32App 1.2.1
$global:AuthenticationHeader = @{
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer $plainToken"
    "ExpiresOn"     = $tokenObj.ExpiresOn.ToString()
}
Write-Host "Auth header set (token expires: $($tokenObj.ExpiresOn))"

Write-Host "--- 2. Check existing app ---"

$existingApp = Get-IntuneWin32App -DisplayName $appName -ErrorAction SilentlyContinue |
               Where-Object { $_.displayName -eq $appName } |
               Select-Object -First 1

if ($existingApp) {
    Write-Host "Found existing app - ID: $($existingApp.id)  Version: $($existingApp.displayVersion)"
    if ($existingApp.displayVersion -eq $appVersion -and -not $forceUpdate) {
        Write-Host "Same version already deployed. Skipping."
        exit 0
    }
    Write-Host "Updating to v$appVersion"
} else {
    Write-Host "App not found - will create new."
}

Write-Host "--- 3. Build detection rule ---"

$configRaw = Get-Content "app-config.json" | ConvertFrom-Json
$detectCfg = $configRaw.detectionRule

$detectionRule = switch ($detectCfg.type) {
    "msi" {
        Write-Host "Detection: MSI $($detectCfg.productCode)"
        New-IntuneWin32AppDetectionRuleMSI `
            -ProductCode            $detectCfg.productCode `
            -ProductVersionOperator "greaterThanOrEqual" `
            -ProductVersion         $appVersion
    }
    "registry" {
        New-IntuneWin32AppDetectionRuleRegistry `
            -KeyPath       $detectCfg.keyPath `
            -ValueName     $detectCfg.valueName `
            -DetectionType "string" `
            -Operator      "equal" `
            -Value         $appVersion
    }
    "file" {
        New-IntuneWin32AppDetectionRuleFile `
            -Path             $detectCfg.path `
            -FileOrFolderName $detectCfg.fileOrFolder `
            -DetectionType    "exists"
    }
}

Write-Host "--- 4. Build requirement rules ---"

$req = $configRaw.requirements
$osVersionMap = @{
    "W10-1809" = "10.0.17763"; "W10-21H2" = "10.0.19044"
    "W11-21H2" = "10.0.22000"; "W11-22H2" = "10.0.22621"; "W11-23H2" = "10.0.22631"
}
$minOs = if ($osVersionMap.ContainsKey($req.minimumOS)) { $osVersionMap[$req.minimumOS] } else { $req.minimumOS }

$reqRules = @(
    New-IntuneWin32AppRequirementRuleOperatingSystem `
        -MinimumSupportedWindowsRelease $minOs `
        -Architecture $req.architecture
)

Write-Host "--- 5. Create / Update app ---"

$installExp = if ($configRaw.installExperience) { $configRaw.installExperience } else { "system" }
$restart    = if ($configRaw.restartBehavior)   { $configRaw.restartBehavior }   else { "suppress" }

if ($existingApp) {
    $patchBody = @{
        displayName          = $appName
        displayVersion       = $appVersion
        description          = $description
        publisher            = $publisher
        installCommandLine   = $installCmd
        uninstallCommandLine = $uninstallCmd
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod `
        -Method  PATCH `
        -Uri     "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($existingApp.id)" `
        -Headers $global:AuthenticationHeader `
        -Body    $patchBody
    Write-Host "Metadata updated"

    Update-IntuneWin32AppPackageFile -ID $existingApp.id -FilePath $pkgPath
    Write-Host "Package uploaded"
    $appId = $existingApp.id
}
else {
    $newApp = Add-IntuneWin32App `
        -FilePath             $pkgPath `
        -DisplayName          $appName `
        -AppVersion           $appVersion `
        -Description          $description `
        -Publisher            $publisher `
        -InstallCommandLine   $installCmd `
        -UninstallCommandLine $uninstallCmd `
        -InstallExperience    $installExp `
        -RestartBehavior      $restart `
        -DetectionRule        $detectionRule `
        -RequirementRule      $reqRules

    if (-not $newApp) {
        Write-Error "Add-IntuneWin32App returned null."
        exit 1
    }
    Write-Host "App created - ID: $($newApp.id)"
    $appId = $newApp.id
}

Write-Host "--- 6. Assign to All Devices ---"

$assignments   = Get-IntuneWin32AppAssignment -ID $appId -ErrorAction SilentlyContinue
$hasAllDevices = $assignments | Where-Object { $_.target.'@odata.type' -match 'allDevices' }

if ($hasAllDevices -and -not $forceUpdate) {
    Write-Host "All Devices assignment already present."
} else {
    Add-IntuneWin32AppAssignment `
        -ID           $appId `
        -Target       "allDevices" `
        -Intent       "required" `
        -Notification "showAll"
    Write-Host "Assigned to All Devices (Required)"
}

Write-Host "DEPLOYMENT COMPLETE"
Write-Host "App       : $appName"
Write-Host "Version   : $appVersion"
Write-Host "Intune ID : $appId"
Write-Host "Assignment: All Devices - Required"
