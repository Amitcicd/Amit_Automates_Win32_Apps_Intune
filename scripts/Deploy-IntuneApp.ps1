<#
.SYNOPSIS
    Deploys a Win32 app to Microsoft Intune via Graph API.
    Authenticates using the OIDC token already established by azure/login@v2
    in the calling workflow — no CLIENT_SECRET required.

.NOTES
    This script must run inside an azure/powershell@v2 step so that the
    Az PowerShell context (from azure/login OIDC) is available for
    Get-AzAccessToken. The token is then handed to Connect-MgGraph which
    the IntuneWin32App module uses internally.

    Required Entra app permissions (Application):
      DeviceManagementApps.ReadWrite.All
    
    Federated credential subject for this repo:
      repo:Amitcicd/<this-repo-name>:ref:refs/heads/main
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 0. Bootstrap ──────────────────────────────────────────────────────────────

Write-Host "`n━━━ 0. Bootstrap ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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

# Install modules if not present
foreach ($mod in @("IntuneWin32App","Microsoft.Graph.Authentication")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "📦 Installing module: $mod"
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber
    }
}
Import-Module IntuneWin32App -Force
Import-Module Microsoft.Graph.Authentication -Force

# ── 1. Authenticate via OIDC token ────────────────────────────────────────────

Write-Host "`n━━━ 1. Authenticate (OIDC) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# The azure/login@v2 step already ran and established Az context via OIDC.
# We exchange that for a short-lived MSGraph token — no secret stored anywhere.
try {
    $tokenObj = Get-AzAccessToken -ResourceTypeName MSGraph -AsSecureString -ErrorAction Stop
    Write-Host "✅ Got MSGraph access token via OIDC (expires: $($tokenObj.ExpiresOn))"
}
catch {
    Write-Error "Failed to get MSGraph token from Az context. Ensure azure/login ran first: $_"
    exit 1
}

# Connect-MgGraph with the token (IntuneWin32App uses MgGraph internally)
Connect-MgGraph -AccessToken $tokenObj.Token -NoWelcome
Write-Host "✅ Connected to Microsoft Graph"

# ── 2. Check if app already exists ───────────────────────────────────────────

Write-Host "`n━━━ 2. Check existing app ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

$existingApp = Get-IntuneWin32App -DisplayName $appName -ErrorAction SilentlyContinue |
               Where-Object { $_.displayName -eq $appName } |
               Select-Object -First 1

if ($existingApp) {
    Write-Host "🔍 Found existing app — ID: $($existingApp.id)  Version: $($existingApp.displayVersion)"
    if ($existingApp.displayVersion -eq $appVersion -and -not $forceUpdate) {
        Write-Host "⏭️  Same version already deployed and FORCE_UPDATE=false. Skipping."
        exit 0
    }
    Write-Host "🔄 Will update to v$appVersion"
} else {
    Write-Host "➕ App not found — will create new."
}

# ── 3. Build detection rule ───────────────────────────────────────────────────

Write-Host "`n━━━ 3. Build detection rule ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

$configRaw = Get-Content "app-config.json" | ConvertFrom-Json
$detectCfg = $configRaw.detectionRule

$detectionRule = switch ($detectCfg.type) {
    "msi" {
        Write-Host "Detection: MSI product code $($detectCfg.productCode)"
        New-IntuneWin32AppDetectionRuleMSI `
            -ProductCode             $detectCfg.productCode `
            -ProductVersionOperator  "greaterThanOrEqual" `
            -ProductVersion          $appVersion
    }
    "registry" {
        Write-Host "Detection: Registry $($detectCfg.keyPath) \ $($detectCfg.valueName)"
        New-IntuneWin32AppDetectionRuleRegistry `
            -KeyPath       $detectCfg.keyPath `
            -ValueName     $detectCfg.valueName `
            -DetectionType "string" `
            -Operator      "equal" `
            -Value         $appVersion
    }
    "file" {
        Write-Host "Detection: File $($detectCfg.path) \ $($detectCfg.fileOrFolder)"
        New-IntuneWin32AppDetectionRuleFile `
            -Path             $detectCfg.path `
            -FileOrFolderName $detectCfg.fileOrFolder `
            -DetectionType    "exists"
    }
    default {
        Write-Error "Unknown detectionRule.type: $($detectCfg.type). Allowed: msi, registry, file"
        exit 1
    }
}

# ── 4. Requirement rules ──────────────────────────────────────────────────────

Write-Host "`n━━━ 4. Build requirement rules ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

$req = $configRaw.requirements
$osVersionMap = @{
    "W10-1809" = "10.0.17763"; "W10-21H2" = "10.0.19044"
    "W11-21H2" = "10.0.22000"; "W11-22H2" = "10.0.22621"; "W11-23H2" = "10.0.22631"
}
$minOs = if ($osVersionMap.ContainsKey($req.minimumOS)) { $osVersionMap[$req.minimumOS] } else { $req.minimumOS }
Write-Host "Min OS: $minOs  |  Arch: $($req.architecture)"

$reqRules = @(
    New-IntuneWin32AppRequirementRuleOperatingSystem `
        -MinimumSupportedWindowsRelease $minOs `
        -Architecture $req.architecture
)

# ── 5. Create or Update ───────────────────────────────────────────────────────

Write-Host "`n━━━ 5. Create / Update app ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

$installExp = if ($configRaw.installExperience) { $configRaw.installExperience } else { "system" }
$restart    = if ($configRaw.restartBehavior)   { $configRaw.restartBehavior }   else { "suppress" }

if ($existingApp) {
    # Patch metadata via Graph directly
    $patchBody = @{
        displayName          = $appName
        displayVersion       = $appVersion
        description          = $description
        publisher            = $publisher
        installCommandLine   = $installCmd
        uninstallCommandLine = $uninstallCmd
    } | ConvertTo-Json -Depth 5

    Invoke-MgGraphRequest `
        -Method  PATCH `
        -Uri     "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($existingApp.id)" `
        -Body    $patchBody `
        -ContentType "application/json"
    Write-Host "✅ Metadata updated"

    Write-Host "⬆️  Uploading updated package..."
    Update-IntuneWin32AppPackageFile -ID $existingApp.id -FilePath $pkgPath
    Write-Host "✅ Package uploaded"
    $appId = $existingApp.id
}
else {
    Write-Host "⬆️  Creating new Win32 app..."
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
    Write-Host "✅ App created — ID: $($newApp.id)"
    $appId = $newApp.id
}

# ── 6. Assign to All Devices ──────────────────────────────────────────────────

Write-Host "`n━━━ 6. Assign to All Devices ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

$assignments = Get-IntuneWin32AppAssignment -ID $appId -ErrorAction SilentlyContinue
$hasAllDevices = $assignments | Where-Object { $_.target.'@odata.type' -match 'allDevices' }

if ($hasAllDevices -and -not $forceUpdate) {
    Write-Host "⏭️  All Devices assignment already present. Skipping."
} else {
    Add-IntuneWin32AppAssignment `
        -ID           $appId `
        -Target       "allDevices" `
        -Intent       "required" `
        -Notification "showAll"
    Write-Host "✅ Assigned to All Devices (Required)"
}

# ── 7. Summary ────────────────────────────────────────────────────────────────

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Host "🎉 DEPLOYMENT COMPLETE"
Write-Host "   App       : $appName"
Write-Host "   Version   : $appVersion"
Write-Host "   Intune ID : $appId"
Write-Host "   Auth      : OIDC (no secrets)"
Write-Host "   Assignment: All Devices — Required"
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n"
