#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Uninstall wrapper — called by Intune as the uninstall command.

    Example uninstall command in app-config.json:
        "uninstallCommand": "powershell.exe -ExecutionPolicy Bypass -File uninstall.ps1"
#>

$ErrorActionPreference = "Stop"
$logDir  = "$env:ProgramData\IntuneApps\MyApp"
$logFile = "$logDir\uninstall.log"

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Message" | Tee-Object -FilePath $logFile -Append | Write-Host
}

Write-Log "=== Uninstall started ==="

try {
    $productCode = "{YOUR-PRODUCT-CODE-GUID-HERE}"   # <-- replace
    Write-Log "Product code: $productCode"

    $args = @("/x", $productCode, "/qn", "/norestart",
              "/l*v", "`"$logDir\msi-uninstall.log`"")

    $proc = Start-Process "msiexec.exe" -ArgumentList $args -Wait -PassThru
    Write-Log "Exit code: $($proc.ExitCode)"

    if ($proc.ExitCode -notin @(0, 1605)) {   # 1605 = not installed (already removed)
        throw "MSI uninstall returned unexpected exit code $($proc.ExitCode)"
    }

    Write-Log "=== Uninstall succeeded ==="
    exit 0
}
catch {
    Write-Log "ERROR: $_"
    exit 1
}
