Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "--- 0. Bootstrap ---"

$requiredEnv = @("APP_NAME","APP_VERSION","INSTALL_CMD","UNINSTALL_CMD","INTUNEWIN_PATH")
foreach ($v in $requiredEnv) {
    if ([string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($v))) {
        Write-Error "Missing required environment variable: $v"; exit 1
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

Write-Host "App     : $appName v$appVersion"
Write-Host "Package : $pkgPath ($([math]::Round((Get-Item $pkgPath).Length/1MB,2)) MB)"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Helper: same pattern as working intune-auto-syn script ──────────────────

function Invoke-GraphJson {
    param(
        [ValidateSet('GET','POST','PATCH','DELETE')] [string] $Method,
        [string] $Uri,
        [hashtable] $Headers,
        $Body
    )
    if ($PSBoundParameters.ContainsKey('Body')) {
        if ($Body -is [string]) {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $Body -ContentType "application/json"
        } else {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json -Depth 10) -ContentType "application/json"
        }
    } else {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
    }
}

# ── 1. Auth via OIDC (replaces client_credentials in working script) ─────────

Write-Host "--- 1. Authenticate (OIDC) ---"

$tokenObj   = Get-AzAccessToken -ResourceTypeName MSGraph -AsSecureString -ErrorAction Stop
$plainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
)

# Same header pattern as working script
$headers = @{ Authorization = "Bearer $plainToken" }
$base    = "https://graph.microsoft.com/beta"
Write-Host "Auth token acquired via OIDC (expires: $($tokenObj.ExpiresOn))"

# ── 2. Read .intunewin metadata ───────────────────────────────────────────────

Write-Host "--- 2. Read .intunewin metadata ---"

$configRaw = Get-Content "app-config.json" | ConvertFrom-Json

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip      = [System.IO.Compression.ZipFile]::OpenRead($pkgPath)
$xmlEntry = $zip.Entries | Where-Object { $_.Name -eq "Detection.xml" } | Select-Object -First 1
$reader   = New-Object System.IO.StreamReader($xmlEntry.Open())
$xml      = [xml]$reader.ReadToEnd()
$reader.Close()
$encEntry      = $zip.Entries | Where-Object { $_.Name -eq "IntunePackage.intunewin" } | Select-Object -First 1
$encryptedSize = $encEntry.Length
$zip.Dispose()

$enc           = $xml.ApplicationInfo.EncryptionInfo
$fileSize      = [long]$xml.ApplicationInfo.UnencryptedContentSize
$setupFilePath = $configRaw.setupFile   # e.g. npp.8.9.5.Installer.x64.msi

Write-Host "Setup file   : $setupFilePath"
Write-Host "Content size : $fileSize  Encrypted: $encryptedSize"

# ── 3. Check existing app ─────────────────────────────────────────────────────

Write-Host "--- 3. Check existing app ---"

$dn       = $appName.Replace("'","''")
$existing = Invoke-GraphJson -Method GET -Uri "$base/deviceAppManagement/mobileApps?`$filter=displayName eq '$dn'" -Headers $headers
$existingApp = $existing.value | Where-Object { $_.displayName -eq $appName } | Select-Object -First 1

if ($existingApp) {
    Write-Host "Found: $($existingApp.id)  v$($existingApp.displayVersion)"
    if ($existingApp.displayVersion -eq $appVersion -and -not $forceUpdate) {
        Write-Host "Same version deployed. Skipping."; exit 0
    }
    $appId = $existingApp.id
} else {
    Write-Host "Not found - creating new."
    $appId = $null
}

# ── 4. Create or update app shell ─────────────────────────────────────────────

Write-Host "--- 4. Create / update app shell ---"

$detectCfg = $configRaw.detectionRule
$detectionRules = @()
if ($detectCfg.type -eq "msi") {
    $detectionRules = @(@{
        "@odata.type"          = "#microsoft.graph.win32LobAppProductCodeDetection"
        productCode            = $detectCfg.productCode
        productVersion         = $appVersion
        productVersionOperator = "greaterThanOrEqual"
    })
}

$appBody = @{
    "@odata.type"        = "#microsoft.graph.win32LobApp"
    displayName          = $appName
    displayVersion       = $appVersion
    description          = $description
    publisher            = $publisher
    fileName             = $setupFilePath
    setupFilePath        = $setupFilePath
    installCommandLine   = $installCmd
    uninstallCommandLine = $uninstallCmd
    installExperience    = @{ runAsAccount = "system"; deviceRestartBehavior = "suppress" }
    detectionRules       = $detectionRules
    minimumSupportedWindowsRelease = "1903"
}

if ($appId) {
    Invoke-GraphJson -Method PATCH -Uri "$base/deviceAppManagement/mobileApps/$appId" -Headers $headers -Body $appBody
    Write-Host "App updated"
} else {
    $newApp = Invoke-GraphJson -Method POST -Uri "$base/deviceAppManagement/mobileApps" -Headers $headers -Body $appBody
    $appId  = $newApp.id
    Write-Host "App created: $appId"
}

# ── 5. Upload content ─────────────────────────────────────────────────────────

Write-Host "--- 5. Upload content ---"

# Create content version
$cv   = Invoke-GraphJson -Method POST -Uri "$base/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions" -Headers $headers -Body "{}"
$cvId = $cv.id
Write-Host "Content version: $cvId"

# Create file entry
$fileEntry = Invoke-GraphJson -Method POST `
    -Uri "$base/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files" `
    -Headers $headers `
    -Body @{
        name          = "IntunePackage.intunewin"
        size          = $fileSize
        sizeEncrypted = $encryptedSize
        isDependency  = $false
    }
$fileId = $fileEntry.id
Write-Host "File entry: $fileId"

# Wait for SAS URI
Write-Host "Waiting for SAS URI..."
$waited = 0
do {
    Start-Sleep -Seconds 3; $waited += 3
    $fileEntry = Invoke-GraphJson -Method GET `
        -Uri "$base/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId" `
        -Headers $headers
    Write-Host "State: $($fileEntry.uploadState)"
} while (-not $fileEntry.azureStorageUri -and $waited -lt 60)

if (-not $fileEntry.azureStorageUri) { Write-Error "No SAS URI received"; exit 1 }

# Extract encrypted content and upload to Azure Blob
$zip2      = [System.IO.Compression.ZipFile]::OpenRead($pkgPath)
$encEntry2 = $zip2.Entries | Where-Object { $_.Name -eq "IntunePackage.intunewin" } | Select-Object -First 1
$encStream = $encEntry2.Open()
$encBytes  = New-Object byte[] $encryptedSize
$encStream.Read($encBytes, 0, $encryptedSize) | Out-Null
$encStream.Close()
$zip2.Dispose()

Write-Host "Uploading $([math]::Round($encryptedSize/1MB,2)) MB to Azure Blob..."
Invoke-RestMethod -Method PUT -Uri $fileEntry.azureStorageUri -Body $encBytes -Headers @{
    "x-ms-blob-type" = "BlockBlob"
}
Write-Host "Upload complete"

# Commit file
Invoke-GraphJson -Method POST `
    -Uri "$base/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId/commit" `
    -Headers $headers `
    -Body @{
        fileEncryptionInfo = @{
            encryptionKey        = $enc.EncryptionKey
            macKey               = $enc.MacKey
            initializationVector = $enc.InitializationVector
            mac                  = $enc.Mac
            profileIdentifier    = $enc.ProfileIdentifier
            fileDigest           = $enc.FileDigest
            fileDigestAlgorithm  = $enc.FileDigestAlgorithm
        }
    }

# Wait for commit
Write-Host "Waiting for commit..."
$waited = 0
do {
    Start-Sleep -Seconds 5; $waited += 5
    $fileEntry = Invoke-GraphJson -Method GET `
        -Uri "$base/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId" `
        -Headers $headers
    Write-Host "Upload state: $($fileEntry.uploadState)"
} while ($fileEntry.uploadState -notmatch "commitFile" -and $waited -lt 120)

# Commit content version to app
Invoke-GraphJson -Method PATCH -Uri "$base/deviceAppManagement/mobileApps/$appId" -Headers $headers -Body @{
    "@odata.type"           = "#microsoft.graph.win32LobApp"
    committedContentVersion = $cvId
}
Write-Host "Content version committed"

# ── 6. Assign to All Devices ──────────────────────────────────────────────────

Write-Host "--- 6. Assign to All Devices ---"

Invoke-GraphJson -Method POST `
    -Uri "$base/deviceAppManagement/mobileApps/$appId/assign" `
    -Headers $headers `
    -Body @{
        mobileAppAssignments = @(@{
            "@odata.type" = "#microsoft.graph.mobileAppAssignment"
            intent        = "required"
            target        = @{ "@odata.type" = "#microsoft.graph.allDevicesAssignmentTarget" }
            settings      = @{
                "@odata.type"                = "#microsoft.graph.win32LobAppAssignmentSettings"
                notifications                = "showAll"
                deliveryOptimizationPriority = "notConfigured"
            }
        })
    }
Write-Host "Assigned to All Devices (Required)"

Write-Host "DEPLOYMENT COMPLETE"
Write-Host "App       : $appName"
Write-Host "Version   : $appVersion"
Write-Host "Intune ID : $appId"
Write-Host "Auth      : OIDC"
Write-Host "Assignment: All Devices - Required"
