# Intune Win32 App — GitHub Actions CI/CD Pipeline

Automates the full lifecycle of a Win32 app in Microsoft Intune:  
**Build → Package → Upload → Assign (All Devices) → Version-track**

---

## 📁 Repo Structure

```
.
├── .github/
│   └── workflows/
│       └── intune-deploy.yml       # Pipeline definition
├── app/
│   ├── setup.msi                   # Your installer (or .exe)
│   ├── install.ps1                 # Optional install wrapper
│   └── uninstall.ps1               # Optional uninstall wrapper
├── scripts/
│   ├── Get-InstallerVersion.ps1    # Reads version from MSI/EXE metadata
│   └── Deploy-IntuneApp.ps1       # Main deploy orchestrator
└── app-config.json                 # App metadata & detection rules
```

---

## ⚙️ One-Time Setup

### 1. Entra ID App Registration

1. **Azure Portal → Entra ID → App registrations → New registration**
2. Name: `GitHub-Intune-Deploy` (or similar), Accounts: *this tenant only*
3. **API Permissions → Add → Microsoft Graph → Application permissions:**
   - `DeviceManagementApps.ReadWrite.All`
4. **Grant admin consent**
5. **Certificates & Secrets → New client secret** — copy the value

### 2. GitHub Secrets

Go to **Settings → Secrets and variables → Actions → New repository secret**:

| Secret name     | Value                                         |
|-----------------|-----------------------------------------------|
| `TENANT_ID`     | Your Entra tenant ID (GUID)                   |
| `CLIENT_ID`     | App registration Application (client) ID      |
| `CLIENT_SECRET` | Client secret value from step 1               |

### 3. (Optional) GitHub Environment

For production gating (manual approval before deploy):
1. **Settings → Environments → New environment → `production`**
2. Add required reviewers

---

## 🔧 Configure Your App

Edit **`app-config.json`**:

```jsonc
{
  "displayName":    "My App",
  "publisher":      "Contoso IT",
  "setupFile":      "setup.msi",          // filename inside /app
  "installerType":  "msi",               // "msi" or "exe"
  "installCommand": "msiexec /i setup.msi /qn /norestart",
  "uninstallCommand": "msiexec /x {GUID} /qn /norestart",
  "detectionRule": {
    "type": "msi",
    "productCode": "{YOUR-PRODUCT-GUID}"  // from msiinfo or Orca
  },
  "requirements": {
    "minimumOS": "W10-21H2",             // see allowed values in config
    "architecture": "x64",
    "minimumDiskSpaceInMB": 500
  }
}
```

**Detection rule types supported:** `msi`, `registry`, `file`

---

## 🚀 Pipeline Triggers

| Event                    | Behaviour                         |
|--------------------------|-----------------------------------|
| Push to `main`           | Full pipeline runs automatically  |
| `workflow_dispatch`      | Manual run; optionally force-update same version |

---

## 🔄 Pipeline Jobs

```
prepare ──► build ──► deploy ──► release
```

| Job       | What it does                                                          |
|-----------|-----------------------------------------------------------------------|
| `prepare` | Reads `app-config.json`, extracts version from installer metadata     |
| `build`   | Downloads IntuneWinAppUtil, packages `.intunewin`, uploads as artifact |
| `deploy`  | Creates or updates app in Intune; assigns to All Devices (Required)   |
| `release` | Creates a GitHub Release with `.intunewin` attached for audit trail   |

**Version deduplication:** If the same version is already deployed, the pipeline skips upload/assign (unless `force_update` is true).

---

## 🏷️ Version Tracking

Versions are read directly from installer metadata at build time:

- **MSI** → `ProductVersion` property (via Windows Installer COM)
- **EXE** → `ProductVersion` field from the PE resource block

Each successful deploy creates a GitHub Release tagged:
```
v{app-version}-{run-number}
```
e.g. `v3.2.1.0-47`

GitHub Releases serve as your full audit log: who deployed, what version, what commit, when.

---

## 🔒 Security Notes

- Secrets are never logged; they're injected as environment variables
- The Entra ID app should have **only** `DeviceManagementApps.ReadWrite.All` — no broader Graph permissions
- The `production` environment gate (optional) adds a human approval step before any device receives the app
- `.intunewin` artifacts are stored in GitHub for 90 days and attached to releases indefinitely

---

## 🛠️ Local Testing

```powershell
# Test version extraction locally
.\scripts\Get-InstallerVersion.ps1 -InstallerPath .\app\setup.msi -InstallerType msi

# Test packaging (requires IntuneWinAppUtil.exe in PATH or current dir)
.\IntuneWinAppUtil.exe -c app -s setup.msi -o output -q

# Test deploy script (set env vars first)
$env:TENANT_ID     = "..."
$env:CLIENT_ID     = "..."
$env:CLIENT_SECRET = "..."
$env:APP_NAME      = "My App"
$env:APP_VERSION   = "3.2.1.0"
$env:INSTALL_CMD   = "msiexec /i setup.msi /qn"
$env:UNINSTALL_CMD = "msiexec /x {GUID} /qn"
$env:INTUNEWIN_PATH = ".\output\setup.intunewin"
.\scripts\Deploy-IntuneApp.ps1
```

---

## 📌 Get MSI Product Code (for detection rule)

```powershell
# Option A — PowerShell (no extra tools)
$db = New-Object -ComObject WindowsInstaller.Installer
$db.OpenDatabase(".\setup.msi",0).OpenView("SELECT Value FROM Property WHERE Property='ProductCode'") | ForEach-Object { $_.Execute(); $_.Fetch().StringData(1) }

# Option B — Orca (free MSI editor from Windows SDK)
# Open MSI → Property table → ProductCode row
```
