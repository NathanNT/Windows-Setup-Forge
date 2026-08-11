# SetupForge

SetupForge is a small PowerShell/WPF app for preparing fresh Windows 10/11 machines.

It can install selected apps with WinGet, detect already installed software, run VM deployment helpers, launch Win11Debloat after confirmation, and execute a local custom post-setup script.

## Download And Run

```powershell
$d="$env:TEMP\SetupForge"; rm $d -Recurse -Force -ea 0; mkdir $d|out-null; iwr https://github.com/NathanNT/Windows-Setup-Forge/archive/refs/heads/main.zip -OutFile "$d\setup.zip"; Expand-Archive "$d\setup.zip" $d -Force; cd "$d\Windows-Setup-Forge-main"; .\Start-Setup.bat
```

## Launch

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Start-Setup.ps1
```

You can also double-click `Start-Setup.bat`.

## Main Features

- WinGet app installation from `apps.json`.
- Categories, search, recommended profile, select all, clear all.
- Installed-app detection with parallel checks.
- Local app logos.
- Logs in `logs\`.
- VM helpers:
  - VMware Tools from mounted VMware Tools ISO.
  - VirtualBox Guest Additions from mounted Guest Additions ISO.
  - Enable Remote Desktop.
  - Disable Sticky/Filter Keys shortcuts.
- Optional Win11Debloat launcher from the official GitHub archive.
- Local custom hook: `custom\CustomScript.ps1`.

## Custom Script

`custom\CustomScript.ps1` is local-only and ignored by git.

Use the example if needed:

```powershell
Copy-Item .\custom\CustomScript.example.ps1 .\custom\CustomScript.ps1
```

## Add An App

Edit `apps.json`:

```json
{
  "name": "Visual Studio Code",
  "id": "Microsoft.VisualStudioCode",
  "category": "Development",
  "description": "Source code editor",
  "logoText": "VS",
  "accentColor": "#007ACC",
  "logoPath": "assets/logos/vscode.png",
  "logoUrl": "https://www.google.com/s2/favicons?sz=128&domain_url=https%3A%2F%2Fcode.visualstudio.com",
  "recommended": true,
  "requiresAdmin": false,
  "verifyCommand": "code --version"
}
```

Find IDs with:

```powershell
winget search <name>
```

## Structure

```text
setup_manager/
├── Start-Setup.ps1
├── Start-Setup.bat
├── apps.json
├── README.md
├── .gitignore
├── src/
├── assets/
├── custom/
├── external/
└── logs/
```

## Notes

- `logs\` and `external\` are runtime folders and are ignored except for `.gitkeep`.
- `custom\CustomScript.ps1` is intentionally not versioned.
- Win11Debloat is external; read its prompts before applying changes.
- Remote Desktop hosting is not available on Windows Home.
