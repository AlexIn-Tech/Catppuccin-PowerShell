# Catppuccin PowerShell Setup

A repeatable PowerShell script that provisions a Catppuccin Macchiato command-line setup on Windows. It installs and configures Windows Terminal, PowerShell 7, Oh My Posh, PSReadLine, and the bundled FiraCode Nerd Font.

![Windows Terminal with Catppuccin Macchiato and WinFetch](assets/images/winfetch-preview.png)

## What it does

- Installs Windows Terminal, PowerShell 7, and Oh My Posh with WinGet.
- Installs the repository-bundled FiraCode Nerd Font for the current user—no font download required.
- Exports the `catppuccin_macchiato` Oh My Posh theme locally.
- Adds a managed Catppuccin block to the PowerShell 7 profile with PSReadLine prediction and syntax colors.
- Creates a Catppuccin Macchiato color scheme, app theme, and PowerShell 7 profile in Windows Terminal.
- Creates timestamped backups of existing Windows Terminal and PowerShell profile files before changing them.

## Requirements

- Windows 10 or Windows 11
- WinGet (included with current Windows 11 installations)
- An internet connection for WinGet packages and the Oh My Posh theme export

Run the script as your normal user. Administrator access is normally not required, though a package installer may request elevation.

## Install

Clone or download this repository, then run the setup script from the repository root:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Setup-CatppuccinPowerShell.ps1
```

To also ask WinGet to update packages that are already installed:

```powershell
.\Setup-CatppuccinPowerShell.ps1 -UpgradePackages
```

Close every Windows Terminal window and open it again when setup finishes.

## Safety and scope

The script does not contain machine-specific values, user names, host names, API keys, or network addresses. It changes only the current user's PowerShell profile, current-user font registry entries, and Windows Terminal settings. Review the script before running it, as you should with any setup script.

## Font license

`assets/fonts/FiraCode.zip` is FiraCode Nerd Font. It is distributed under the SIL Open Font License 1.1; the included license copy is at [licenses/FiraCode-OFL.txt](licenses/FiraCode-OFL.txt).

## License

This project is licensed under the [MIT License](LICENSE).
