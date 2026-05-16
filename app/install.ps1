#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install wrapper — called by Intune as the install command.
    Adapt for your actual installer (MSI, EXE, MSIX, etc.)

    Example install command in app-config.json:
        "installCommand": "powershell.exe -ExecutionPolicy Bypass -File install.ps1"
#>

$ErrorActionPreference = "Stop"
$logDir  = "$env:ProgramData\IntuneApps\MyApp"
$logFile = "$logDir\install.log"

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Message" | Tee-Object -FilePath $logFile -Append | Write-Host
}

Write-Log "=== Install started ==="

try {
    $installer = Join-Path $PSScriptRoot "setup.msi"
    Write-Log "Installer: $installer"

    $args = @("/i", "`"$installer`"", "/qn", "/norestart", "ALLUSERS=1",
              "/l*v", "`"$logDir\msi.log`"")

    $proc = Start-Process "msiexec.exe" -ArgumentList $args -Wait -PassThru
    Write-Log "Exit code: $($proc.ExitCode)"

    if ($proc.ExitCode -notin @(0, 3010)) {
        throw "MSI returned unexpected exit code $($proc.ExitCode)"
    }

    Write-Log "=== Install succeeded ==="
    exit 0
}
catch {
    Write-Log "ERROR: $_"
    exit 1
}
