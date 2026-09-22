#Requires -Version 5.1
<#
.SYNOPSIS
    Provision a modern Windows command-line environment:
    Windows Terminal + PowerShell 7 + PSReadLine + Oh My Posh +
    FiraCode Nerd Font + WinFetch + Catppuccin Macchiato.

.DESCRIPTION
    Designed to be safe to re-run on multiple Windows computers.

    The script:
      - Ensures Windows Terminal, PowerShell 7, and Oh My Posh are installed with WinGet.
      - Relaunches itself under PowerShell 7 when started from Windows PowerShell 5.1.
      - Installs the bundled FiraCode Nerd Font for the current user.
      - Installs WinFetch and configures it with the bundled Catppuccin Windows image.
      - Exports the Oh My Posh catppuccin_macchiato theme locally.
      - Adds/replaces a managed block in the PowerShell 7 profile.
      - Enables PSReadLine history prediction and Catppuccin syntax colors.
      - Adds Catppuccin Macchiato to Windows Terminal.
      - Sets the Nerd Font and Catppuccin scheme as Terminal profile defaults.
      - Creates a deterministic PowerShell 7 Terminal profile and makes it the default.
      - Adds a Catppuccin Macchiato Windows Terminal application theme.
      - Creates timestamped backups before modifying existing Terminal/profile files.

.NOTES
    Run as your normal user. Administrator rights are not required for the normal setup.
    WinGet may display UAC if a package installer requires elevation.
#>

[CmdletBinding()]
param(
    [string]$FontName = 'FiraCode',
    [string]$FontFace = 'FiraCode Nerd Font',
    [string]$OhMyPoshTheme = 'catppuccin_macchiato',
    [switch]$UpgradePackages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Keep native-tool non-zero exit codes under our explicit handling below.
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$ManagedBlockStart = '# >>> Catppuccin PowerShell Setup >>>'
$ManagedBlockEnd   = '# <<< Catppuccin PowerShell Setup <<<'
$TerminalSchemeName = 'Catppuccin Macchiato'
$PowerShellProfileGuid = '{a10f37f2-4b02-4d7b-88a8-19b5d2b1056e}'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Warning $Message
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Assert-WinGet {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw @'
WinGet was not found.
Install/update "App Installer" from Microsoft, then run this script again.
WinGet is included with current Windows 11 installations.
'@
    }
}

function Test-WinGetPackage {
    param([Parameter(Mandatory)][string]$Id)

    $output = & winget.exe list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    return ($output -match [regex]::Escape($Id))
}

function Ensure-WinGetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$DisplayName
    )

    if (Test-WinGetPackage -Id $Id) {
        Write-Ok "$DisplayName is installed."

        if ($UpgradePackages) {
            Write-Host "    Checking for an upgrade..."
            & winget.exe upgrade --id $Id --exact --source winget `
                --accept-source-agreements --accept-package-agreements `
                --silent --disable-interactivity | Out-Host

            # WinGet can return a non-zero code when no upgrade is available.
            # That is not fatal for provisioning.
        }
        return
    }

    Write-Host "    Installing $DisplayName..."
    & winget.exe install --id $Id --exact --source winget `
        --accept-source-agreements --accept-package-agreements `
        --silent --disable-interactivity | Out-Host

    if ($LASTEXITCODE -ne 0) {
        throw "WinGet failed to install $DisplayName ($Id). Exit code: $LASTEXITCODE"
    }

    Refresh-ProcessPath
    Write-Ok "$DisplayName installed."
}

function Get-PwshPath {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $defaultPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path $defaultPath) {
        return $defaultPath
    }

    throw 'PowerShell 7 was installed but pwsh.exe could not be located.'
}

function Backup-File {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$Path.backup-$timestamp"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Read-JsoncAsHashtable {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return [ordered]@{}
    }

    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }

    # Windows Terminal accepts JSONC. Normalize comments/trailing commas with
    # System.Text.Json, then deserialize to an OrderedHashtable for easy edits.
    $documentOptions = [System.Text.Json.JsonDocumentOptions]::new()
    $documentOptions.AllowTrailingCommas = $true
    $documentOptions.CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip

    $nodeOptions = [System.Text.Json.Nodes.JsonNodeOptions]::new()
    $node = [System.Text.Json.Nodes.JsonNode]::Parse($raw, $nodeOptions, $documentOptions)
    $normalized = $node.ToJsonString()

    return ($normalized | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Ensure-DictionaryChild {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parent,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not $Parent.Contains($Key) -or $null -eq $Parent[$Key]) {
        $Parent[$Key] = [ordered]@{}
    }

    if ($Parent[$Key] -isnot [System.Collections.IDictionary]) {
        throw "Expected '$Key' to be a JSON object."
    }

    return $Parent[$Key]
}

function Set-ManagedProfileBlock {
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Block
    )

    $directory = Split-Path -Parent $ProfilePath
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (Test-Path $ProfilePath) {
        $backup = Backup-File -Path $ProfilePath
        Write-Ok "PowerShell profile backup: $backup"
        $content = [System.IO.File]::ReadAllText($ProfilePath)
    }
    else {
        $content = ''
    }

    $escapedStart = [regex]::Escape($ManagedBlockStart)
    $escapedEnd = [regex]::Escape($ManagedBlockEnd)
    $pattern = "(?s)$escapedStart.*?$escapedEnd"

    if ([regex]::IsMatch($content, $pattern)) {
        $newContent = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Block })
    }
    else {
        $separator = if ([string]::IsNullOrWhiteSpace($content)) { '' } else { "`r`n`r`n" }
        $newContent = $content.TrimEnd() + $separator + $Block + "`r`n"
    }

    Write-Utf8NoBom -Path $ProfilePath -Content $newContent
}

function Test-FontInstalled {
    param([Parameter(Mandatory)][string]$FaceName)

    $fontRegistryKeys = @(
        'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts',
        'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    )

    foreach ($key in $fontRegistryKeys) {
        if (-not (Test-Path $key)) {
            continue
        }

        $properties = (Get-ItemProperty -Path $key).PSObject.Properties
        if ($properties.Name | Where-Object { $_ -like "*$FaceName*" }) {
            return $true
        }
    }

    return $false
}

function Install-BundledNerdFont {
    param([Parameter(Mandatory)][string]$ArchivePath)

    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        throw "Bundled Nerd Font archive was not found: $ArchivePath"
    }

    $fontDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $fontRegistryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    $extractionDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("CatppuccinPowerShell-Fonts-" + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $fontDirectory -Force | Out-Null
        New-Item -Path $fontRegistryPath -Force | Out-Null
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractionDirectory -Force

        $fontFiles = Get-ChildItem -LiteralPath $extractionDirectory -Filter '*.ttf' -File -Recurse
        if (-not $fontFiles) {
            throw "No .ttf files were found in the bundled archive: $ArchivePath"
        }

        foreach ($fontFile in $fontFiles) {
            $destination = Join-Path $fontDirectory $fontFile.Name
            Copy-Item -LiteralPath $fontFile.FullName -Destination $destination -Force

            $registryName = ($fontFile.BaseName -replace 'FiraCodeNerdFont', 'FiraCode Nerd Font') + ' (TrueType)'
            New-ItemProperty -Path $fontRegistryPath -Name $registryName -Value $fontFile.Name -PropertyType String -Force | Out-Null
        }
    }
    finally {
        if (Test-Path -LiteralPath $extractionDirectory) {
            Remove-Item -LiteralPath $extractionDirectory -Recurse -Force
        }
    }
}

function Ensure-WinFetch {
    Write-Step 'Installing WinFetch'

    $installedScript = $null
    if (Get-Command Get-InstalledScript -ErrorAction SilentlyContinue) {
        $installedScript = Get-InstalledScript -Name 'winfetch' -ErrorAction SilentlyContinue
    }

    if ($installedScript) {
        Write-Ok 'WinFetch is installed.'
        return
    }

    if (-not (Get-Command Install-Script -ErrorAction SilentlyContinue)) {
        throw 'Install-Script is unavailable. Install PowerShellGet, then run this script again.'
    }

    Install-Script -Name 'winfetch' -Scope CurrentUser -Force
    Write-Ok 'WinFetch installed.'
}

function Configure-WinFetch {
    Write-Step 'Configuring WinFetch'

    $sourceImage = Join-Path $PSScriptRoot 'assets\images\windows-catppuccin.png'
    if (-not (Test-Path -LiteralPath $sourceImage)) {
        throw "Bundled WinFetch image was not found: $sourceImage"
    }

    $configDirectory = Join-Path $HOME '.config\winfetch'
    $configPath = Join-Path $configDirectory 'config.ps1'
    $imagePath = Join-Path $configDirectory 'windows-catppuccin.png'
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null

    if (Test-Path -LiteralPath $configPath) {
        $backup = Backup-File -Path $configPath
        Write-Ok "WinFetch config backup: $backup"
    }

    Copy-Item -LiteralPath $sourceImage -Destination $imagePath -Force
    $config = @'
# Managed by Setup-CatppuccinPowerShell.ps1. Re-run the setup script to update.
$image = Join-Path $HOME '.config\winfetch\windows-catppuccin.png'
$imgwidth = 35
$showpkgs = @('winget')
'@
    Write-Utf8NoBom -Path $configPath -Content ($config + "`r`n")
    Write-Ok "WinFetch configured: $configPath"

    return $configPath
}

function Get-WindowsTerminalSettingsPath {
    $stable = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    $unpackaged = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'

    if (Test-Path $stable) {
        return $stable
    }

    if (Test-Path $unpackaged) {
        return $unpackaged
    }

    # We install the stable Terminal package, so prefer its documented location.
    return $stable
}

function Configure-WindowsTerminal {
    param(
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$FaceName
    )

    Write-Step 'Configuring Windows Terminal'

    $settingsPath = Get-WindowsTerminalSettingsPath
    $settingsDirectory = Split-Path -Parent $settingsPath
    if (-not (Test-Path $settingsDirectory)) {
        New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    }

    if (Test-Path $settingsPath) {
        $backup = Backup-File -Path $settingsPath
        Write-Ok "Windows Terminal backup: $backup"
        $settings = Read-JsoncAsHashtable -Path $settingsPath
    }
    else {
        $settings = [ordered]@{
            '$schema' = 'https://aka.ms/terminal-profiles-schema'
        }
    }

    if ($settings -isnot [System.Collections.IDictionary]) {
        throw 'Windows Terminal settings root is not a JSON object.'
    }

    # Official Catppuccin Macchiato ANSI palette.
    $scheme = [ordered]@{
        name                = $TerminalSchemeName
        cursorColor         = '#F4DBD6'
        selectionBackground = '#5B6078'
        background          = '#24273A'
        foreground          = '#CAD3F5'
        black               = '#494D64'
        red                 = '#ED8796'
        green               = '#A6DA95'
        yellow              = '#EED49F'
        blue                = '#8AADF4'
        purple              = '#F5BDE6'
        cyan                = '#8BD5CA'
        white               = '#B8C0E0'
        brightBlack         = '#5B6078'
        brightRed           = '#ED8796'
        brightGreen         = '#A6DA95'
        brightYellow        = '#EED49F'
        brightBlue          = '#8AADF4'
        brightPurple        = '#F5BDE6'
        brightCyan          = '#8BD5CA'
        brightWhite         = '#A5ADCB'
    }

    $existingSchemes = @()
    if ($settings.Contains('schemes') -and $null -ne $settings['schemes']) {
        $existingSchemes = @($settings['schemes'])
    }

    $filteredSchemes = @(
        $existingSchemes | Where-Object {
            -not ($_ -is [System.Collections.IDictionary] -and $_.Contains('name') -and $_['name'] -eq $TerminalSchemeName)
        }
    )
    $settings['schemes'] = @($filteredSchemes) + @($scheme)

    # Apply scheme/font to all Terminal profiles by default.
    $profiles = Ensure-DictionaryChild -Parent $settings -Key 'profiles'
    $defaults = Ensure-DictionaryChild -Parent $profiles -Key 'defaults'
    $font = Ensure-DictionaryChild -Parent $defaults -Key 'font'
    $font['face'] = $FaceName
    $defaults['colorScheme'] = $TerminalSchemeName

    # Guarantee a working PowerShell 7 profile even if Terminal's dynamic profile
    # generation is unavailable/disabled on a particular PC.
    $profileEntry = [ordered]@{
        guid              = $PowerShellProfileGuid
        name              = 'PowerShell 7'
        commandline       = $PwshPath
        startingDirectory = '%USERPROFILE%'
        hidden            = $false
    }

    $profileList = @()
    if ($profiles.Contains('list') -and $null -ne $profiles['list']) {
        $profileList = @($profiles['list'])
    }

    $profileList = @(
        $profileList | Where-Object {
            -not ($_ -is [System.Collections.IDictionary] -and $_.Contains('guid') -and $_['guid'] -eq $PowerShellProfileGuid)
        }
    )
    $profiles['list'] = @($profileList) + @($profileEntry)
    $settings['defaultProfile'] = $PowerShellProfileGuid

    # Theme the Terminal chrome/tab bar too, not just ANSI terminal colors.
    $appTheme = [ordered]@{
        name = $TerminalSchemeName
        tab = [ordered]@{
            background          = '#24273AFF'
            showCloseButton     = 'always'
            unfocusedBackground = $null
        }
        tabRow = [ordered]@{
            background          = '#1E2030FF'
            unfocusedBackground = '#181926FF'
        }
        window = [ordered]@{
            applicationTheme = 'dark'
        }
    }

    $existingThemes = @()
    if ($settings.Contains('themes') -and $null -ne $settings['themes']) {
        $existingThemes = @($settings['themes'])
    }

    $filteredThemes = @(
        $existingThemes | Where-Object {
            -not ($_ -is [System.Collections.IDictionary] -and $_.Contains('name') -and $_['name'] -eq $TerminalSchemeName)
        }
    )
    $settings['themes'] = @($filteredThemes) + @($appTheme)
    $settings['theme'] = $TerminalSchemeName

    $json = $settings | ConvertTo-Json -Depth 100
    Write-Utf8NoBom -Path $settingsPath -Content ($json + "`r`n")
    Write-Ok "Windows Terminal configured: $settingsPath"
}

# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------

Write-Step 'Checking prerequisites'
Assert-WinGet

# Install PowerShell 7 first so the rest of the setup runs in modern PowerShell.
Ensure-WinGetPackage -Id 'Microsoft.PowerShell' -DisplayName 'PowerShell 7'
Refresh-ProcessPath

if ($PSVersionTable.PSVersion.Major -lt 7) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Save this script as a .ps1 file before running it from Windows PowerShell 5.1.'
    }

    $pwsh = Get-PwshPath
    Write-Step "Relaunching setup under PowerShell 7 ($pwsh)"

    $forwardArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-FontName', $FontName,
        '-FontFace', $FontFace,
        '-OhMyPoshTheme', $OhMyPoshTheme
    )
    if ($UpgradePackages) {
        $forwardArguments += '-UpgradePackages'
    }

    & $pwsh @forwardArguments
    exit $LASTEXITCODE
}

Write-Ok "Running PowerShell $($PSVersionTable.PSVersion)"

# -----------------------------------------------------------------------------
# Packages
# -----------------------------------------------------------------------------

Write-Step 'Installing command-line components'
Ensure-WinGetPackage -Id 'Microsoft.WindowsTerminal' -DisplayName 'Windows Terminal'
Ensure-WinGetPackage -Id 'JanDeDobbeleer.OhMyPosh' -DisplayName 'Oh My Posh'
Refresh-ProcessPath

$pwshPath = Get-PwshPath
$ompCommand = Get-Command oh-my-posh.exe -ErrorAction SilentlyContinue
if (-not $ompCommand) {
    $ompCommand = Get-Command oh-my-posh -ErrorAction SilentlyContinue
}
if (-not $ompCommand) {
    throw 'Oh My Posh was installed but its executable is not available on PATH.'
}
$omp = $ompCommand.Source

# -----------------------------------------------------------------------------
# Nerd Font
# -----------------------------------------------------------------------------

Write-Step "Installing Nerd Font: $FontName"
if (Test-FontInstalled -FaceName $FontFace) {
    Write-Ok "$FontFace is already installed."
}
else {
    $bundledFontArchive = Join-Path $PSScriptRoot 'assets\fonts\FiraCode.zip'
    Install-BundledNerdFont -ArchivePath $bundledFontArchive
    Write-Ok "$FontFace installed."
}

# -----------------------------------------------------------------------------
# Local Oh My Posh configuration
# -----------------------------------------------------------------------------

Write-Step "Preparing Oh My Posh theme: $OhMyPoshTheme"
$ompConfigDirectory = Join-Path $HOME '.config\oh-my-posh'
$ompConfigPath = Join-Path $ompConfigDirectory "$OhMyPoshTheme.omp.json"
New-Item -ItemType Directory -Path $ompConfigDirectory -Force | Out-Null

& $omp config export --config $OhMyPoshTheme --output $ompConfigPath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ompConfigPath)) {
    throw "Failed to export Oh My Posh theme '$OhMyPoshTheme'."
}
Write-Ok "Local prompt theme: $ompConfigPath"

# -----------------------------------------------------------------------------
# WinFetch
# -----------------------------------------------------------------------------

Ensure-WinFetch
$winFetchConfigPath = Configure-WinFetch

# -----------------------------------------------------------------------------
# PowerShell execution policy (only loosen Restricted -> RemoteSigned)
# -----------------------------------------------------------------------------

Write-Step 'Checking PowerShell profile execution policy'
$effectivePolicy = Get-ExecutionPolicy
if ($effectivePolicy -eq 'Restricted') {
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
        $effectivePolicy = Get-ExecutionPolicy
        Write-Ok "Execution policy set to RemoteSigned for CurrentUser."
    }
    catch {
        Write-Warn "Could not change execution policy: $($_.Exception.Message)"
    }
}
else {
    Write-Ok "Effective execution policy: $effectivePolicy"
}

if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Warn 'Execution policy is still Restricted (possibly via Group Policy). The PowerShell profile may not auto-load.'
}

# -----------------------------------------------------------------------------
# PowerShell profile + PSReadLine + Oh My Posh
# -----------------------------------------------------------------------------

Write-Step 'Configuring PowerShell 7 profile'
$profilePath = $PROFILE.CurrentUserCurrentHost

$profileBlock = @"
$ManagedBlockStart
# Managed by Setup-CatppuccinPowerShell.ps1. Re-run the setup script to update.

# PSReadLine ------------------------------------------------------------------
Import-Module PSReadLine

Set-PSReadLineOption -PredictionSource History
Set-PSReadLineOption -PredictionViewStyle InlineView
Set-PSReadLineOption -HistoryNoDuplicates

# Catppuccin Macchiato PSReadLine palette
Set-PSReadLineOption -Colors @{
    Command          = "``e[38;2;138;173;244m" # Blue
    Parameter        = "``e[38;2;198;160;246m" # Mauve
    Operator         = "``e[38;2;145;215;227m" # Sky
    Variable         = "``e[38;2;183;189;248m" # Lavender
    String           = "``e[38;2;166;218;149m" # Green
    Number           = "``e[38;2;245;169;127m" # Peach
    Type             = "``e[38;2;238;212;159m" # Yellow
    Comment          = "``e[38;2;110;115;141m" # Overlay0
    Keyword          = "``e[38;2;198;160;246m" # Mauve
    Member           = "``e[38;2;139;213;202m" # Teal
    Emphasis         = "``e[38;2;245;189;230m" # Pink
    Error            = "``e[38;2;237;135;150m" # Red
    InlinePrediction = "``e[38;2;91;96;120m"   # Surface2
}

# RightArrow accepts the whole inline prediction (PSReadLine default).
# Ctrl+RightArrow accepts only the next suggested word.
Set-PSReadLineKeyHandler -Chord 'Ctrl+RightArrow' -Function AcceptNextSuggestionWord

# Oh My Posh -----------------------------------------------------------------
`$ompThemePath = Join-Path `$HOME '.config\oh-my-posh\$OhMyPoshTheme.omp.json'
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    oh-my-posh init pwsh --config `$ompThemePath | Invoke-Expression
}
$ManagedBlockEnd
"@

Set-ManagedProfileBlock -ProfilePath $profilePath -Block $profileBlock
Write-Ok "PowerShell profile configured: $profilePath"

# -----------------------------------------------------------------------------
# Windows Terminal
# -----------------------------------------------------------------------------

Configure-WindowsTerminal -PwshPath $pwshPath -FaceName $FontFace

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

Write-Step 'Validating setup'

$validation = [ordered]@{
    'PowerShell'       = $PSVersionTable.PSVersion.ToString()
    'PowerShell path'  = $pwshPath
    'PSReadLine'       = (Get-Module -ListAvailable PSReadLine | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()
    'Oh My Posh'       = (& $omp version | Select-Object -First 1)
    'Nerd Font'        = $FontFace
    'OMP theme'        = $ompConfigPath
    'WinFetch config'  = $winFetchConfigPath
    'PowerShell profile' = $profilePath
    'Terminal settings'  = (Get-WindowsTerminalSettingsPath)
}

$validation.GetEnumerator() | ForEach-Object {
    Write-Host ('    {0,-20} {1}' -f ($_.Key + ':'), $_.Value)
}

$completionMessage = @"

Setup complete.

Close ALL Windows Terminal windows and open Windows Terminal again so the new
font, Terminal theme, default PowerShell 7 profile, PSReadLine settings, and
Oh My Posh prompt are loaded together.

Prediction keys:
  Right Arrow       Accept the entire grey PSReadLine suggestion
  Ctrl+RightArrow   Accept the next suggested word
  Tab               Normal PowerShell/path completion

Re-running this script is safe. Use -UpgradePackages if you also want WinGet to
attempt upgrades of PowerShell, Windows Terminal, and Oh My Posh.
"@
Write-Host $completionMessage -ForegroundColor Green
