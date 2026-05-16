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

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.Graph.Authentication -Force

Write-Host "--- 1. Authenticate (OIDC) ---"

$tokenObj = Get-AzAccessToken -ResourceTypeName MSGraph -AsSecureString -ErrorAction Stop
Connect-MgGraph -AccessToken $tokenObj.Token -NoWelcome
Write-Host "Connected to Microsoft Graph"

$plainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
)
$headers = @{ "Authorization" = "Bearer $plainToken"; "Content-Type" = "application/json" }
$graphBase = "https://graph.microsoft.com/beta"

Write-Host "--- 2. Read .intunewin metadata ---"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($pkgPath)
$xmlEntry = $zip.Entries | Where-Object { $_.Name -eq "Detection.xml" } | Select-Object -First 1
$reader = New-Object System.IO.StreamReader($xmlEntry.Open())
$xml = [xml]$reader.ReadToEnd()
$reader.Close()

$encEntry = $zip.Entries | Where-Object { $_.Name -eq "IntunePackage.intunewin" } | Select-Object -First 1
$encryptedSize = $encEntry.Length
$zip.Dispose()

$enc      = $xml.ApplicationInfo.EncryptionInfo
$fileSize = [long]$xml.ApplicationInfo.UnencryptedContentSize
$fileName = $xml.ApplicationInfo.FileName
Write-Host "File: $fileName  Size: $fileSize  Encrypted: $encryptedSize"

Write-Host "--- 3. Check existing app ---"

$configRaw = Get-Content "app-config.json" | ConvertFrom-Json
$filter = [System.Web.HttpUtility]::UrlEncode("displayName eq '$appName'")
$existing = Invoke-MgGraphRequest -Method GET -Uri "$graphBase/deviceAppManagement/mobileApps?`$filter=displayName eq '$appName'" -Headers $headers
$existingApp = $existing.value | Where-Object { $_.displayName -eq $appName } | Select-Object -First 1

if ($existingApp) {
    Write-Host "Existing app found: $($existingApp.id)  v$($existingApp.displayVersion)"
    if ($existingApp.displayVersion -eq $appVersion -and -not $forceUpdate) {
        Write-Host "Same version deployed. Skipping."
        exit 0
    }
    $appId = $existingApp.id
} else {
    Write-Host "App not found - creating new."
    $appId = $null
}

Write-Host "--- 4. Create or update app shell ---"

$detectCfg = $configRaw.detectionRule
$detectionRules = @()
if ($detectCfg.type -eq "msi") {
    $detectionRules = @(@{
        "@odata.type"    = "#microsoft.graph.win32LobAppProductCodeDetection"
        productCode      = $detectCfg.productCode
        productVersion   = $appVersion
        productVersionOperator = "greaterThanOrEqual"
    })
}

$appBody = @{
    "@odata.type"        = "#microsoft.graph.win32LobApp"
    displayName          = $appName
    displayVersion       = $appVersion
    description          = $description
    publisher            = $publisher
    fileName             = $fileName
    installCommandLine   = $installCmd
    uninstallCommandLine = $uninstallCmd
    installExperience    = @{ runAsAccount = "system"; deviceRestartBehavior = "suppress" }
    detectionRules       = $detectionRules
    minimumSupportedWindowsRelease = "1903"
} | ConvertTo-Json -Depth 10

if ($appId) {
    Invoke-MgGraphRequest -Method PATCH -Uri "$graphBase/deviceAppManagement/mobileApps/$appId" -Body $appBody -Headers $headers -ContentType "application/json"
    Write-Host "App metadata updated"
} else {
    $newApp = Invoke-MgGraphRequest -Method POST -Uri "$graphBase/deviceAppManagement/mobileApps" -Body $appBody -Headers $headers -ContentType "application/json"
    $appId = $newApp.id
    Write-Host "App created: $appId"
}

Write-Host "--- 5. Upload content ---"

# Create content version
$cv = Invoke-MgGraphRequest -Method POST `
    -Uri "$graphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions" `
    -Body "{}" -Headers $headers -ContentType "application/json"
$cvId = $cv.id
Write-Host "Content version: $cvId"

# Create file entry
$fileBody = @{
    name           = $fileName
    size           = $fileSize
    sizeEncrypted  = $encryptedSize
    manifest       = $null
    isDependency   = $false
} | ConvertTo-Json

$fileEntry = Invoke-MgGraphRequest -Method POST `
    -Uri "$graphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files" `
    -Body $fileBody -Headers $headers -ContentType "application/json"
$fileId = $fileEntry.id
Write-Host "File entry created: $fileId"

# Wait for SAS URI
Write-Host "Waiting for Azure Storage URI..."
$maxWait = 30
$waited  = 0
do {
    Start-Sleep -Seconds 3
    $waited += 3
    $fileEntry = Invoke-MgGraphRequest -Method GET `
        -Uri "$graphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId" `
        -Headers $headers
} while ((-not $fileEntry.azureStorageUri) -and $waited -lt $maxWait)

if (-not $fileEntry.azureStorageUri) { Write-Error "SAS URI not received"; exit 1 }
Write-Host "SAS URI received"

# Extract encrypted content from .intunewin and upload to Azure Blob
$zip2 = [System.IO.Compression.ZipFile]::OpenRead($pkgPath)
$encEntry2 = $zip2.Entries | Where-Object { $_.Name -eq "IntunePackage.intunewin" } | Select-Object -First 1
$encStream = $encEntry2.Open()
$encBytes  = New-Object byte[] $encryptedSize
$encStream.Read($encBytes, 0, $encryptedSize) | Out-Null
$encStream.Close()
$zip2.Dispose()

$sasUri = $fileEntry.azureStorageUri
$blobHeaders = @{
    "x-ms-blob-type"  = "BlockBlob"
    "Content-Length"  = $encryptedSize.ToString()
}
Write-Host "Uploading $([math]::Round($encryptedSize/1MB,2)) MB to Azure Blob..."
Invoke-RestMethod -Method PUT -Uri $sasUri -Body $encBytes -Headers $blobHeaders
Write-Host "Upload complete"

# Commit file
$commitBody = @{
    fileEncryptionInfo = @{
        encryptionKey        = $enc.EncryptionKey
        macKey               = $enc.MacKey
        initializationVector = $enc.InitializationVector
        mac                  = $enc.Mac
        profileIdentifier    = $enc.ProfileIdentifier
        fileDigest           = $enc.FileDigest
        fileDigestAlgorithm  = $enc.FileDigestAlgorithm
    }
} | ConvertTo-Json -Depth 5

Invoke-MgGraphRequest -Method POST `
    -Uri "$graphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId/commit" `
    -Body $commitBody -Headers $headers -ContentType "application/json"

# Wait for commit
Write-Host "Waiting for file commit..."
$waited = 0
do {
    Start-Sleep -Seconds 5
    $waited += 5
    $fileEntry = Invoke-MgGraphRequest -Method GET `
        -Uri "$graphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId" `
        -Headers $headers
    Write-Host "Upload state: $($fileEntry.uploadState)"
} while ($fileEntry.uploadState -notmatch "commitFile" -and $waited -lt 120)

# Commit content version to app
$cvCommit = @{
    "@odata.type"            = "#microsoft.graph.win32LobApp"
    committedContentVersion  = $cvId
} | ConvertTo-Json

Invoke-MgGraphRequest -Method PATCH -Uri "$graphBase/deviceAppManagement/mobileApps/$appId" `
    -Body $cvCommit -Headers $headers -ContentType "application/json"
Write-Host "Content version committed"

Write-Host "--- 6. Assign to All Devices ---"

$assignBody = @{
    mobileAppAssignments = @(@{
        "@odata.type" = "#microsoft.graph.mobileAppAssignment"
        intent        = "required"
        target        = @{ "@odata.type" = "#microsoft.graph.allDevicesAssignmentTarget" }
        settings      = @{
            "@odata.type"              = "#microsoft.graph.win32LobAppAssignmentSettings"
            notifications              = "showAll"
            restartSettings            = $null
            installTimeSettings        = $null
            deliveryOptimizationPriority = "notConfigured"
        }
    })
} | ConvertTo-Json -Depth 10

Invoke-MgGraphRequest -Method POST `
    -Uri "$graphBase/deviceAppManagement/mobileApps/$appId/assign" `
    -Body $assignBody -Headers $headers -ContentType "application/json"
Write-Host "Assigned to All Devices (Required)"

Write-Host "DEPLOYMENT COMPLETE"
Write-Host "App       : $appName"
Write-Host "Version   : $appVersion"
Write-Host "Intune ID : $appId"
Write-Host "Auth      : OIDC - pure Graph API"
Write-Host "Assignment: All Devices - Required"
