<#
.SYNOPSIS
    Extracts ProductVersion from an MSI or FileVersion from an EXE.

.PARAMETER InstallerPath
    Full or relative path to the installer file.

.PARAMETER InstallerType
    Either "msi" or "exe".

.OUTPUTS
    Version string (e.g. "2.1.4.0") written to stdout.
    Script exits with code 1 on failure.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InstallerPath,

    [Parameter(Mandatory)]
    [ValidateSet("msi", "exe")]
    [string]$InstallerType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-MsiVersion {
    param([string]$Path)

    $fullPath = Resolve-Path $Path
    Write-Verbose "Reading MSI ProductVersion from: $fullPath"

    $installer = $null
    $database  = $null
    $view      = $null

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        # OpenMode 0 = read-only
        $database = $installer.GetType().InvokeMember(
            "OpenDatabase", "InvokeMethod", $null, $installer, @("$fullPath", 0)
        )
        $query = "SELECT Value FROM Property WHERE Property = 'ProductVersion'"
        $view  = $database.GetType().InvokeMember(
            "OpenView", "InvokeMethod", $null, $database, ($query)
        )
        $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null)
        $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, $null)

        if (-not $record) {
            throw "ProductVersion property not found in MSI."
        }

        $version = $record.GetType().InvokeMember("StringData", "GetProperty", $null, $record, 1)
        return $version.Trim()
    }
    finally {
        if ($view)      { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)      | Out-Null }
        if ($database)  { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($database)  | Out-Null }
        if ($installer) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) | Out-Null }
        [System.GC]::Collect()
    }
}

function Get-ExeVersion {
    param([string]$Path)

    $fullPath = Resolve-Path $Path
    Write-Verbose "Reading FileVersionInfo from: $fullPath"

    $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo("$fullPath")

    # Prefer ProductVersion; fall back to FileVersion
    $version = if ($info.ProductVersion -and $info.ProductVersion -match '\d') {
        $info.ProductVersion
    } elseif ($info.FileVersion -and $info.FileVersion -match '\d') {
        $info.FileVersion
    } else {
        $null
    }

    if (-not $version) {
        throw "No ProductVersion or FileVersion found in EXE resource block."
    }

    # Normalise: strip any trailing ' (build ...)' strings some vendors add
    $version = ($version -split '\s')[0].Trim()
    return $version
}

# ── Main ──────────────────────────────────────────────────────────────────────

if (-not (Test-Path $InstallerPath)) {
    Write-Error "Installer not found: $InstallerPath"
    exit 1
}

try {
    $version = switch ($InstallerType.ToLower()) {
        "msi" { Get-MsiVersion -Path $InstallerPath }
        "exe" { Get-ExeVersion -Path $InstallerPath }
    }

    # Validate looks like a version
    if ($version -notmatch '^\d+(\.\d+){1,3}$') {
        Write-Warning "Version '$version' looks unusual — continuing anyway."
    }

    Write-Host $version   # sole stdout line; captured by the workflow step
    exit 0
}
catch {
    Write-Error "Version extraction failed: $_"
    exit 1
}
