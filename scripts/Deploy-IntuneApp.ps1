Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "--- 0. Bootstrap ---"

$requiredEnv = @("APP_NAME","APP_VERSION","INSTALL_CMD","UNUNINSTALL_CMD","INTUNEWIN_PATH")
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

# ── Helper: Graph API calls (same pattern as working intune-auto-syn script) ──

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

# ── Helper: Azure Blob chunked upload ─────────────────────────────────────────

function Upload-AzureBlob {
    param([string]$SasUri, [byte[]]$Bytes)
    $chunkSize = 4 * 1024 * 1024
    $blockIds  = New-Object System.Collections.Generic.List[string]
    $offset    = 0
    $chunkNum  = 0
    while ($offset -lt $Bytes.Length) {
        $length = [Math]::Min($chunkSize, $Bytes.Length - $offset)
        $chunk  = New-Object byte[] $length
        [Array]::Copy($Bytes, $offset, $chunk, 0, $length)
        $blockId = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($chunkNum.ToString("D6")))
        $blockIds.Add($blockId)
        $blockUri = "$SasUri&comp=block&blockid=$([Uri]::EscapeDataString($blockId))"
        Invoke-RestMethod -Method Put -Uri $blockUri -Body $chunk -Headers @{
            "x-ms-blob-type" = "BlockBlob"
            "Content-Type"   = "application/octet-stream"
        } | Out-Null
        Write-Host "  Chunk $chunkNum uploaded ($length bytes)"
        $offset += $length
        $chunkNum++
    }
    $blockListXml = "<?xml version=`"1.0`" encoding=`"utf-8`"?><BlockList>" +
        (($blockIds | ForEach-Object { "<Latest>$_</Latest>" }) -join "") +
        "</BlockList>"
    Invoke-RestMethod -Method Put -Uri "$SasUri&comp=blocklist" -Body ([Text.Encoding]::UTF8.GetBytes($blockListXml)) -Headers @{
        "Content-Type" = "application/xml"
    } | Out-Null
    Write-Host "Block list committed ($chunkNum chunks)"
}

# ── 1. Authenticate via OIDC ──────────────────────────────────────────────────

Write-Host "--- 1. Authenticate (OIDC) ---"

$tokenObj   = Get-AzAccessToken -ResourceTypeName MSGraph -AsSecureString -ErrorAction Stop
$plainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
)
$headers = @{ Authorization = "Bearer $plainToken" }
$base    = "https://graph.microsoft.com/beta"
Write-Host "Auth token acquired (expires: $($tokenObj.ExpiresOn))"

# ── 2. Read .intunewin metadata ───────────────────────────────────────────────

Write-Host "--- 2. Read .intunewin metadata ---"

$configRaw = Get-Content "app-config.json" | ConvertFrom-Json

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip      = [System.IO.Compression.ZipFile]::OpenRead($pkgPath)
$xmlEntry = $zip.Entries | Where-Object { $_.Name -ieq "Detection.xml" } | Select-Object -First 1
if (-not $xmlEntry) {
    Write-Error "Detection.xml not found in $pkgPath"; exit 1
}
$reader   = New-Object System.IO.StreamReader($xmlEntry.Open())
$xml      = [xml]$reader.ReadToEnd()
$reader.Close()
$zip.Dispose()

$enc           = $xml.ApplicationInfo.EncryptionInfo
$fileSize      = [long]$xml.ApplicationInfo.UnencryptedContentSize
$setupFilePath = $configRaw.setupFile

Write-Host "Setup file       : $setupFilePath"
Write-Host "Plain size       : $fileSize"
Write-Host "ProfileIdentifier: $($enc.ProfileIdentifier)"
Write-Host "EncryptionKey len: $($enc.EncryptionKey.Trim().Length)"
Write-Host "MacKey len       : $($enc.MacKey.Trim().Length)"
Write-Host "IV len           : $($enc.InitializationVector.Trim().Length)"
Write-Host "Mac len          : $($enc.Mac.Trim().Length)"
Write-Host "FileDigest len   : $($enc.FileDigest.Trim().Length)"

# ── 3. Read encrypted bytes ───────────────────────────────────────────────────

Write-Host "--- 3. Read encrypted bytes ---"

$zip2      = [System.IO.Compression.ZipFile]::OpenRead($pkgPath)
$encEntry  = $zip2.Entries | Where-Object { $_.Name -ieq "IntunePackage.intunewin" } | Select-Object -First 1
if (-not $encEntry) {
    Write-Error "IntunePackage.intunewin not found in $pkgPath"; exit 1
}
$encStream = $encEntry.Open()
$ms        = New-Object System.IO.MemoryStream
$encStream.CopyTo($ms)
$encBytes  = $ms.ToArray()
$ms.Dispose()
$encStream.Close()
$zip2.Dispose()
$encryptedSize = $encBytes.Length
Write-Host "Encrypted bytes: $encryptedSize"

# Verify MAC matches first 32 bytes of encrypted file
$macFromXml = [Convert]::FromBase64String($enc.Mac.Trim())
$first32    = $encBytes[0..31]
$macMatch   = -not (Compare-Object $macFromXml $first32)
Write-Host "MAC matches file header: $macMatch"

# ── 4. Check existing app ─────────────────────────────────────────────────────

Write-Host "--- 4. Check existing app ---"

$dn          = $appName.Replace("'","''")
$existing    = Invoke-GraphJson -Method GET -Uri "$base/deviceAppManagement/mobileApps?`$filter=displayName eq '$dn'" -Headers $headers
$existingApp = $existing.value | Where-Object { $_.displayName -eq $appName } | Select-Object -First 1

if ($existingApp) {
    Write-Host "Found: $($existingApp.id)  v$($existingApp.displayVersion)"
    if ($existingApp.displayVersion -eq $appVersion -and -not $forceUpdate) {
        Write-Host "Same version deployed. Skipping."
        exit 0
    }
    $appId = $existingApp.id
} else {
    Write-Host "Not found - creating new."
    $appId = $null
}

# ── 5. Create / update app shell ──────────────────────────────────────────────

Write-Host "--- 5. Create / update app shell ---"

$detectionRules = @()
if ($configRaw.detectionRule.type -eq "msi") {
    $detectionRules = @(@{
        "@odata.type"          = "#microsoft.graph.win32LobAppProductCodeDetection"
        productCode            = $configRaw.detectionRule.productCode
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
    Write-Host "App updated: $appId"
} else {
    $newApp = Invoke-GraphJson -Method POST -Uri "$base/deviceAppManagement/mobileApps" -Headers $headers -Body $appBody
    $appId  = $newApp.id
    Write-Host "App created: $appId"
}

# ── 6. Upload content ─────────────────────────────────────────────────────────

Write-Host "--- 6. Upload content ---"

$cv   = Invoke-GraphJson -Method POST `
    -Uri "$base/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions" `
    -Headers $headers -Body "{}"
$cvId = $cv.id
Write-Host "Content version: $cvId"

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

Write-Host "Waiting for SAS URI..."
$waited = 0
do {
    Start-Sleep -Seconds 3; $waited += 3
    $fileEntry = Invoke-GraphJson -Method GET `
        -Uri "$base/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId" `
        -Headers $headers
    Write-Host "State: $($fileEntry.uploadState)"
} while (-not $fileEntry.azureStorageUri -and $waited -lt 60)

if (-not $fileEntry.azureStorageUri) {
    Write-Error "No SAS URI received"; exit 1
}

Write-Host "Uploading via block blob chunks..."
Upload-AzureBlob -SasUri $fileEntry.azureStorageUri -Bytes $encBytes

# ── Commit file ───────────────────────────────────────────────────────────────

Write-Host "Committing file encryption info..."
$commitBody = @{
    fileEncryptionInfo = @{
        "@odata.type"        = "#microsoft.graph.fileEncryptionInfo"
        encryptionKey        = $enc.EncryptionKey.Trim()
        macKey               = $enc.MacKey.Trim()
        initializationVector = $enc.InitializationVector.Trim()
        mac                  = $enc.Mac.Trim()
        profileIdentifier    = $enc.ProfileIdentifier.Trim()
        fileDigest           = $enc.FileDigest.Trim()
        fileDigestAlgorithm  = $enc.FileDigestAlgorithm.Trim()
    }
} | ConvertTo-Json -Depth 5

Invoke-GraphJson -Method POST `
    -Uri "$base/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId/commit" `
    -Headers $headers -Body $commitBody

Write-Host "Waiting for commit..."
$waited = 0
do {
    Start-Sleep -Seconds 5; $waited += 5
    $fileEntry = Invoke-GraphJson -Method GET `
        -Uri "$base/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId" `
        -Headers $headers
    Write-Host "Upload state: $($fileEntry.uploadState) (MAC match was: $macMatch)"
} while ($fileEntry.uploadState -notmatch "commitFile" -and $waited -lt 120)

if ($fileEntry.uploadState -eq "commitFileFailed") {
    Write-Error "File commit failed. MAC match: $macMatch"
    exit 1
}

Invoke-GraphJson -Method PATCH -Uri "$base/deviceAppManagement/mobileApps/$appId" -Headers $headers -Body @{
    "@odata.type"           = "#microsoft.graph.win32LobApp"
    committedContentVersion = $cvId
}
Write-Host "Content version committed"

# ── 7. Assign to All Devices ──────────────────────────────────────────────────

Write-Host "--- 7. Assign to All Devices ---"

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
