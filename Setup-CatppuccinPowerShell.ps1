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

    Resilience:
      - Every optional step is isolated. One failing step warns and the rest of
        the setup still runs; a summary of failures is printed at the end and
        the script exits with a non-zero code.
      - Font files are only rewritten when their contents actually differ, and a
        font that Windows currently has memory-mapped is replaced by renaming the
        in-use file aside first. That is the situation behind the error
        "The requested operation cannot be performed on a file with a
        user-mapped section open."
      - The font step is self-healing: it repairs a half-finished install (files
        present but registry entries missing) instead of skipping or failing.

.PARAMETER LoadFunctionsOnly
    Dot-source the script to define its helper functions without running any of
    the provisioning steps. Used by tests/Setup-CatppuccinPowerShell.Tests.ps1.

.NOTES
    Run as your normal user. Administrator rights are not required for the normal setup.
    WinGet may display UAC if a package installer requires elevation.
#>

[CmdletBinding()]
param(
    [string]$FontName = 'FiraCode',
    [string]$FontFace = 'FiraCode Nerd Font',
    [string]$OhMyPoshTheme = 'catppuccin_macchiato',
    [switch]$UpgradePackages,
    [switch]$LoadFunctionsOnly
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

function Write-Fail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    [FAIL] $Message" -ForegroundColor Red
}

# -----------------------------------------------------------------------------
# Step isolation
#
# A single unavailable component (WinFetch, Windows Terminal, ...) must not cost
# you the whole setup. Non-critical steps record their failure and the script
# keeps going; the summary at the end lists what did not work.
# -----------------------------------------------------------------------------

$script:SetupFailures = [System.Collections.Generic.List[string]]::new()

function Reset-SetupFailures {
    $script:SetupFailures = [System.Collections.Generic.List[string]]::new()
}

function Get-SetupFailures {
    return @($script:SetupFailures)
}

function Invoke-SetupStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Critical
    )

    try {
        # The step runs in its own scope, so anything a later step needs has to
        # come back as output:  $path = Invoke-SetupStep -Name x -Action { ... }
        & $Action
    }
    catch {
        if ($Critical) {
            throw
        }

        $message = "$Name : $($_.Exception.Message)"
        Write-Fail $message
        $script:SetupFailures.Add($message)
    }
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

$UserFontDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$UserFontRegistryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
$MachineFontRegistryPath = 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

# Suffix used for a font file that had to be renamed out of the way because it
# was still mapped into memory. Cleaned up on the next run.
$StaleFontSuffix = '.catppuccin-stale-'

function Test-FontInstalled {
    param(
        [Parameter(Mandatory)][string]$FaceName,
        [string[]]$RegistryPaths = @($UserFontRegistryPath, $MachineFontRegistryPath),
        [string]$FontDirectory = $UserFontDirectory
    )

    foreach ($key in $RegistryPaths) {
        if (-not (Test-Path $key)) {
            continue
        }

        $properties = @((Get-ItemProperty -Path $key).PSObject.Properties)
        foreach ($property in $properties) {
            # Match the display name ("FiraCode Nerd Font Bold (TrueType)") or
            # the file name it points at ("FiraCodeNerdFont-Bold.ttf").
            if ($property.Name -like "*$FaceName*") { return $true }
            if (($property.Value -is [string]) -and ($property.Value -like "*$($FaceName -replace ' ', '')*")) { return $true }
        }
    }

    # A font can be present on disk while its registry entry is missing, e.g.
    # when an earlier run was interrupted partway through.
    $compactName = $FaceName -replace ' ', ''
    foreach ($directory in @($FontDirectory, (Join-Path $env:WINDIR 'Fonts'))) {
        if ([string]::IsNullOrWhiteSpace($directory) -or -not (Test-Path -LiteralPath $directory)) {
            continue
        }

        if (Get-ChildItem -LiteralPath $directory -Filter "$compactName*" -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
            return $true
        }
    }

    return $false
}

function Test-FileContentEqual {
    param(
        [Parameter(Mandatory)][string]$ReferencePath,
        [Parameter(Mandatory)][string]$DifferencePath
    )

    if (-not (Test-Path -LiteralPath $ReferencePath) -or -not (Test-Path -LiteralPath $DifferencePath)) {
        return $false
    }

    $reference = Get-Item -LiteralPath $ReferencePath
    $difference = Get-Item -LiteralPath $DifferencePath
    if ($reference.Length -ne $difference.Length) {
        return $false
    }

    try {
        $referenceHash = (Get-FileHash -LiteralPath $ReferencePath -Algorithm SHA256).Hash
        $differenceHash = (Get-FileHash -LiteralPath $DifferencePath -Algorithm SHA256).Hash
        return ($referenceHash -eq $differenceHash)
    }
    catch {
        # Unreadable destination: treat it as different so we try to replace it.
        return $false
    }
}

function Get-FontDisplayName {
    <#
        Reads the full font name (name ID 4) out of the TrueType 'name' table so
        the registry gets the name Windows itself would use. Falls back to the
        file's base name, which is still unique and stable, if anything about
        the file is unexpected.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $fallback = [System.IO.Path]::GetFileNameWithoutExtension($Path)

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]'ReadWrite, Delete'))
    }
    catch {
        return $fallback
    }

    try {
        function Read-Exact {
            param($Stream, [int]$Count)
            $buffer = New-Object byte[] $Count
            $read = 0
            while ($read -lt $Count) {
                $chunk = $Stream.Read($buffer, $read, $Count - $read)
                if ($chunk -le 0) { throw 'Unexpected end of font file.' }
                $read += $chunk
            }
            return $buffer
        }
        function Get-UInt16BE { param($Bytes, [int]$Offset) return [int](([int]$Bytes[$Offset] -shl 8) -bor [int]$Bytes[$Offset + 1]) }
        function Get-UInt32BE {
            param($Bytes, [int]$Offset)
            return ([uint32]$Bytes[$Offset] -shl 24) -bor ([uint32]$Bytes[$Offset + 1] -shl 16) -bor
                   ([uint32]$Bytes[$Offset + 2] -shl 8) -bor [uint32]$Bytes[$Offset + 3]
        }

        $header = Read-Exact -Stream $stream -Count 12

        # TrueType collection: jump to the first font's offset table.
        if ([System.Text.Encoding]::ASCII.GetString($header, 0, 4) -eq 'ttcf') {
            $stream.Position = 12
            $offsets = Read-Exact -Stream $stream -Count 4
            $stream.Position = [int](Get-UInt32BE -Bytes $offsets -Offset 0)
            $header = Read-Exact -Stream $stream -Count 12
        }

        $tableCount = Get-UInt16BE -Bytes $header -Offset 4
        if ($tableCount -le 0 -or $tableCount -gt 512) { return $fallback }

        $records = Read-Exact -Stream $stream -Count ($tableCount * 16)
        $nameTableOffset = -1
        for ($i = 0; $i -lt $tableCount; $i++) {
            $recordOffset = $i * 16
            if ([System.Text.Encoding]::ASCII.GetString($records, $recordOffset, 4) -eq 'name') {
                $nameTableOffset = [int](Get-UInt32BE -Bytes $records -Offset ($recordOffset + 8))
                break
            }
        }
        if ($nameTableOffset -lt 0) { return $fallback }

        $stream.Position = $nameTableOffset
        $nameHeader = Read-Exact -Stream $stream -Count 6
        $recordCount = Get-UInt16BE -Bytes $nameHeader -Offset 2
        $stringStorageOffset = Get-UInt16BE -Bytes $nameHeader -Offset 4
        if ($recordCount -le 0) { return $fallback }

        $nameRecords = Read-Exact -Stream $stream -Count ($recordCount * 12)

        $best = $null
        $bestRank = -1
        for ($i = 0; $i -lt $recordCount; $i++) {
            $offset = $i * 12
            $platformId = Get-UInt16BE -Bytes $nameRecords -Offset $offset
            $nameId = Get-UInt16BE -Bytes $nameRecords -Offset ($offset + 6)
            if ($nameId -ne 4) { continue }   # 4 = full font name

            # Prefer the Windows/Unicode record, fall back to the Macintosh one.
            $rank = if ($platformId -eq 3) { 2 } elseif ($platformId -eq 1) { 1 } else { 0 }
            if ($rank -le $bestRank) { continue }

            $length = Get-UInt16BE -Bytes $nameRecords -Offset ($offset + 8)
            $stringOffset = Get-UInt16BE -Bytes $nameRecords -Offset ($offset + 10)
            if ($length -le 0) { continue }

            $stream.Position = $nameTableOffset + $stringStorageOffset + $stringOffset
            $stringBytes = Read-Exact -Stream $stream -Count $length
            $value = if ($platformId -eq 3) {
                [System.Text.Encoding]::BigEndianUnicode.GetString($stringBytes)
            }
            else {
                [System.Text.Encoding]::ASCII.GetString($stringBytes)
            }

            $value = $value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $best = $value
                $bestRank = $rank
            }
        }

        if ([string]::IsNullOrWhiteSpace($best)) { return $fallback }
        return $best
    }
    catch {
        return $fallback
    }
    finally {
        $stream.Dispose()
    }
}

function Copy-FontFile {
    <#
        Copies a font into place without ever aborting the setup.

        Windows refuses to overwrite a file that has an open user-mapped
        section, which is exactly what happens when the font is already loaded:
            "The requested operation cannot be performed on a file with a
             user-mapped section open."

        The file can still be *renamed* though, so an in-use font is moved aside
        and the new one is copied into the freed name. The renamed leftover is
        deleted if Windows lets go of it, and otherwise cleaned up on a later run.

        Returns an object with Status =
            UpToDate | Copied | Replaced | Failed
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MaxAttempts = 3,
        [int]$RetryDelayMilliseconds = 400
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Source font file was not found: $SourcePath"
    }

    $name = Split-Path -Leaf $DestinationPath
    $existed = Test-Path -LiteralPath $DestinationPath

    if ($existed -and (Test-FileContentEqual -ReferencePath $SourcePath -DifferencePath $DestinationPath)) {
        return [pscustomobject]@{ Name = $name; Status = 'UpToDate'; Message = $null }
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
            $status = if ($existed) { 'Replaced' } else { 'Copied' }
            return [pscustomobject]@{ Name = $name; Status = $status; Message = $null }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        if (Test-Path -LiteralPath $DestinationPath) {
            $stalePath = "$DestinationPath$StaleFontSuffix$([guid]::NewGuid().ToString('N').Substring(0, 8))"
            try {
                Rename-Item -LiteralPath $DestinationPath -NewName (Split-Path -Leaf $stalePath) -ErrorAction Stop
                Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
                Remove-Item -LiteralPath $stalePath -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ Name = $name; Status = 'Replaced'; Message = $null }
            }
            catch {
                $lastError = $_.Exception.Message
                # Put the original name back if the rename worked but the copy did not.
                if ((Test-Path -LiteralPath $stalePath) -and -not (Test-Path -LiteralPath $DestinationPath)) {
                    Rename-Item -LiteralPath $stalePath -NewName $name -ErrorAction SilentlyContinue
                }
            }
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }

    return [pscustomobject]@{ Name = $name; Status = 'Failed'; Message = $lastError }
}

function Register-FontFile {
    <#
        Writes the HKCU font registry entry only when it is missing or wrong, so
        re-runs stay quiet. Returns 'UpToDate' or 'Registered'.
    #>
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$FileName
    )

    $existing = Get-ItemProperty -Path $RegistryPath -Name $DisplayName -ErrorAction SilentlyContinue
    if ($existing -and ($existing.$DisplayName -eq $FileName)) {
        return 'UpToDate'
    }

    New-ItemProperty -Path $RegistryPath -Name $DisplayName -Value $FileName -PropertyType String -Force | Out-Null
    return 'Registered'
}

function Add-FontToCurrentSession {
    <#
        Best-effort: make the font usable without signing out, the way the
        Windows font installer does (AddFontResource + WM_FONTCHANGE broadcast).
        Purely cosmetic - never let it break the setup.
    #>
    param([Parameter(Mandatory)][string[]]$Paths)

    try {
        if (-not ('CatppuccinSetup.NativeFonts' -as [type])) {
            Add-Type -Namespace 'CatppuccinSetup' -Name 'NativeFonts' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("gdi32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int AddFontResourceW(string lpFileName);

[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern int SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam, uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
'@ -ErrorAction Stop
        }

        foreach ($path in $Paths) {
            [void][CatppuccinSetup.NativeFonts]::AddFontResourceW($path)
        }

        $HWND_BROADCAST = [System.IntPtr]0xFFFF
        $WM_FONTCHANGE = 0x001D
        $SMTO_ABORTIFHUNG = 0x0002
        $result = [System.IntPtr]::Zero
        [void][CatppuccinSetup.NativeFonts]::SendMessageTimeout($HWND_BROADCAST, $WM_FONTCHANGE,
            [System.IntPtr]::Zero, [System.IntPtr]::Zero, $SMTO_ABORTIFHUNG, 1000, [ref]$result)
        return $true
    }
    catch {
        return $false
    }
}

function Install-BundledNerdFont {
    <#
        Installs every .ttf from the bundled archive for the current user.

        Idempotent and self-healing: unchanged files are left alone, changed
        files are replaced even while in use, and missing registry entries are
        recreated. A file that genuinely cannot be written is reported and the
        remaining fonts are still installed.
    #>
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [string]$FontDirectory = $UserFontDirectory,
        [string]$RegistryPath = $UserFontRegistryPath,
        [int]$MaxAttempts = 3,
        [int]$RetryDelayMilliseconds = 400,
        # Loading a font into the current process maps the file into memory,
        # which is undesirable when installing into a throwaway directory.
        [switch]$SkipSessionRegistration
    )

    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        throw "Bundled Nerd Font archive was not found: $ArchivePath"
    }

    $extractionDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("CatppuccinPowerShell-Fonts-" + [guid]::NewGuid().ToString('N'))

    $summary = [ordered]@{
        Total      = 0
        Installed  = 0   # copied or replaced
        UpToDate   = 0
        Registered = 0
        Failed     = @()
    }

    try {
        New-Item -ItemType Directory -Path $FontDirectory -Force | Out-Null

        # NEVER use New-Item -Force on an existing registry key: for the
        # registry provider that recreates the key and silently deletes every
        # value in it, i.e. every font the user already had registered.
        if (-not (Test-Path -LiteralPath $RegistryPath)) {
            New-Item -Path $RegistryPath -Force | Out-Null
        }

        try {
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractionDirectory -Force
        }
        catch {
            throw "Could not extract the bundled font archive '$ArchivePath': $($_.Exception.Message)"
        }

        $fontFiles = @(Get-ChildItem -LiteralPath $extractionDirectory -Filter '*.ttf' -File -Recurse)
        if ($fontFiles.Count -eq 0) {
            throw "No .ttf files were found in the bundled archive: $ArchivePath"
        }

        $summary.Total = $fontFiles.Count
        $installedPaths = [System.Collections.Generic.List[string]]::new()
        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($fontFile in $fontFiles) {
            $destination = Join-Path $FontDirectory $fontFile.Name

            $copy = Copy-FontFile -SourcePath $fontFile.FullName -DestinationPath $destination `
                -MaxAttempts $MaxAttempts -RetryDelayMilliseconds $RetryDelayMilliseconds

            switch ($copy.Status) {
                'UpToDate' { $summary.UpToDate++ }
                'Failed'   { $failures.Add("$($fontFile.Name): $($copy.Message)") }
                default    { $summary.Installed++ }
            }

            if ($copy.Status -eq 'Failed') {
                continue
            }

            $installedPaths.Add($destination)

            # Register against the file that is actually on disk.
            $displayName = (Get-FontDisplayName -Path $destination) + ' (TrueType)'
            try {
                if ((Register-FontFile -RegistryPath $RegistryPath -DisplayName $displayName -FileName $fontFile.Name) -eq 'Registered') {
                    $summary.Registered++
                }
            }
            catch {
                $failures.Add("$($fontFile.Name) (registry): $($_.Exception.Message)")
            }
        }

        # Typed so the property is always an array, never $null.
        $summary.Failed = [string[]]@($failures)

        if ($installedPaths.Count -gt 0 -and -not $SkipSessionRegistration) {
            [void](Add-FontToCurrentSession -Paths @($installedPaths))
        }

        Remove-StaleFontLeftovers -FontDirectory $FontDirectory | Out-Null
    }
    finally {
        if (Test-Path -LiteralPath $extractionDirectory) {
            Remove-Item -LiteralPath $extractionDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]$summary
}

function Remove-StaleFontLeftovers {
    <#
        Deletes font files that a previous run had to rename out of the way
        because they were still in use. Best-effort by design.
    #>
    param([Parameter(Mandatory)][string]$FontDirectory)

    if (-not (Test-Path -LiteralPath $FontDirectory)) {
        return 0
    }

    $removed = 0
    $leftovers = @(Get-ChildItem -LiteralPath $FontDirectory -Filter "*$StaleFontSuffix*" -File -ErrorAction SilentlyContinue)
    foreach ($leftover in $leftovers) {
        try {
            Remove-Item -LiteralPath $leftover.FullName -Force -ErrorAction Stop
            $removed++
        }
        catch {
            # Still mapped into memory - try again after the next sign-out.
        }
    }

    return $removed
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

# Dot-sourced by the test suite: stop here with only the helpers defined.
if ($LoadFunctionsOnly) {
    return
}

Reset-SetupFailures

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

# Deliberately unconditional. The install is idempotent and repairs partial
# state (files present but unregistered, or an outdated file that is currently
# in use), which a simple "is it installed?" check would skip right past.
Invoke-SetupStep -Name 'Nerd Font' -Action {
    $bundledFontArchive = Join-Path $PSScriptRoot 'assets\fonts\FiraCode.zip'
    $fontResult = Install-BundledNerdFont -ArchivePath $bundledFontArchive

    Write-Ok ("$FontFace - {0} file(s): {1} installed, {2} already current, {3} registry entry(ies) written." -f
        $fontResult.Total, $fontResult.Installed, $fontResult.UpToDate, $fontResult.Registered)

    if (@($fontResult.Failed).Count -gt 0) {
        foreach ($failure in $fontResult.Failed) {
            Write-Warn "Font not updated - $failure"
        }
        throw ("{0} of {1} font files could not be written. Close Windows Terminal and any app using FiraCode, then re-run this script." -f
            @($fontResult.Failed).Count, $fontResult.Total)
    }
} | Out-Null

# -----------------------------------------------------------------------------
# Local Oh My Posh configuration
# -----------------------------------------------------------------------------

Write-Step "Preparing Oh My Posh theme: $OhMyPoshTheme"
$ompConfigDirectory = Join-Path $HOME '.config\oh-my-posh'
$ompConfigPath = Join-Path $ompConfigDirectory "$OhMyPoshTheme.omp.json"

Invoke-SetupStep -Name 'Oh My Posh theme' -Action {
    New-Item -ItemType Directory -Path $ompConfigDirectory -Force | Out-Null

    if (Test-Path -LiteralPath $ompConfigPath) {
        $backup = Backup-File -Path $ompConfigPath
        Write-Ok "Oh My Posh theme backup: $backup"
    }

    & $omp config export --config $OhMyPoshTheme --output $ompConfigPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ompConfigPath)) {
        throw "Failed to export Oh My Posh theme '$OhMyPoshTheme'."
    }

    # An empty or malformed export would break every new shell, so check it.
    try {
        Get-Content -Raw -LiteralPath $ompConfigPath | ConvertFrom-Json -ErrorAction Stop | Out-Null
    }
    catch {
        throw "Exported Oh My Posh theme '$ompConfigPath' is not valid JSON: $($_.Exception.Message)"
    }

    Write-Ok "Local prompt theme: $ompConfigPath"
} | Out-Null

# -----------------------------------------------------------------------------
# WinFetch
# -----------------------------------------------------------------------------

$winFetchConfigPath = Invoke-SetupStep -Name 'WinFetch' -Action {
    Ensure-WinFetch | Out-Null
    Configure-WinFetch
}
if (-not $winFetchConfigPath) {
    $winFetchConfigPath = '(not configured)'
}

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

Invoke-SetupStep -Name 'PowerShell profile' -Action {
    Set-ManagedProfileBlock -ProfilePath $profilePath -Block $profileBlock

    # A profile that does not parse breaks every new shell, so verify it.
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($profilePath, [ref]$null, [ref]$parseErrors) | Out-Null
    if (@($parseErrors).Count -gt 0) {
        throw "The generated profile has $(@($parseErrors).Count) syntax error(s): $($parseErrors[0].Message)"
    }

    Write-Ok "PowerShell profile configured: $profilePath"
} | Out-Null

# -----------------------------------------------------------------------------
# Windows Terminal
# -----------------------------------------------------------------------------

Invoke-SetupStep -Name 'Windows Terminal' -Action {
    Configure-WindowsTerminal -PwshPath $pwshPath -FaceName $FontFace
} | Out-Null

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

Write-Step 'Validating setup'

# Each check answers "is this actually true on disk right now?", independently
# of whether the step that was supposed to do it reported success.
function Test-SetupCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Check
    )

    try {
        $detail = & $Check
        if ($detail) {
            Write-Host ('    [PASS] {0,-22} {1}' -f $Name, $detail) -ForegroundColor Green
            return $true
        }
        Write-Fail ('{0,-22} check returned no result' -f $Name)
        return $false
    }
    catch {
        Write-Fail ('{0,-22} {1}' -f $Name, $_.Exception.Message)
        return $false
    }
}

$checks = [ordered]@{
    'PowerShell 7' = {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'not running under PowerShell 7' }
        "$($PSVersionTable.PSVersion) ($pwshPath)"
    }
    'PSReadLine' = {
        $module = Get-Module -ListAvailable PSReadLine | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $module) { throw 'module not found' }
        $module.Version.ToString()
    }
    'Oh My Posh' = {
        $version = & $omp version 2>$null | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($version)) { throw 'oh-my-posh did not report a version' }
        $version
    }
    'Nerd Font' = {
        if (-not (Test-FontInstalled -FaceName $FontFace)) { throw "$FontFace is not installed" }
        $registered = @((Get-ItemProperty -Path $UserFontRegistryPath -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object { $_.Name -like "*$FontFace*" }).Count
        "$FontFace ($registered registry entries)"
    }
    'Prompt theme' = {
        if (-not (Test-Path -LiteralPath $ompConfigPath)) { throw "missing: $ompConfigPath" }
        Get-Content -Raw -LiteralPath $ompConfigPath | ConvertFrom-Json -ErrorAction Stop | Out-Null
        $ompConfigPath
    }
    'WinFetch' = {
        if (-not (Test-Path -LiteralPath $winFetchConfigPath)) { throw "missing: $winFetchConfigPath" }
        $winFetchConfigPath
    }
    'PowerShell profile' = {
        if (-not (Test-Path -LiteralPath $profilePath)) { throw "missing: $profilePath" }
        $content = Get-Content -Raw -LiteralPath $profilePath
        if ($content -notmatch [regex]::Escape($ManagedBlockStart)) { throw 'managed block is missing' }
        $profilePath
    }
    'Terminal settings' = {
        $settingsPath = Get-WindowsTerminalSettingsPath
        if (-not (Test-Path -LiteralPath $settingsPath)) { throw "missing: $settingsPath" }
        $settings = Read-JsoncAsHashtable -Path $settingsPath
        if ($settings['defaultProfile'] -ne $PowerShellProfileGuid) { throw 'PowerShell 7 is not the default profile' }
        if ($settings['profiles']['defaults']['font']['face'] -ne $FontFace) { throw "default font is not $FontFace" }
        if (-not (@($settings['schemes']) | Where-Object { $_['name'] -eq $TerminalSchemeName })) { throw "$TerminalSchemeName scheme is missing" }
        $settingsPath
    }
}

$failedChecks = 0
foreach ($check in $checks.GetEnumerator()) {
    if (-not (Test-SetupCheck -Name $check.Key -Check $check.Value)) {
        $failedChecks++
    }
}

$stepFailures = @(Get-SetupFailures)
if ($stepFailures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($stepFailures.Count) step(s) did not complete:" -ForegroundColor Yellow
    foreach ($failure in $stepFailures) {
        Write-Host "    - $failure" -ForegroundColor Yellow
    }
}

if ($failedChecks -gt 0 -or $stepFailures.Count -gt 0) {
    $incompleteMessage = @"

Setup finished with problems: $failedChecks failed check(s), $($stepFailures.Count) failed step(s).

Everything listed as [PASS] above is in place. Re-running this script is safe
and will retry only what is still missing.

If a font file could not be written, close ALL Windows Terminal windows and any
other app using FiraCode, then run the script again.
"@
    Write-Host $incompleteMessage -ForegroundColor Yellow
    exit 1
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
