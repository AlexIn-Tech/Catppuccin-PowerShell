#
# Tests for Setup-CatppuccinPowerShell.ps1
#
# Run with:  Invoke-Pester -Path .\tests
#
# The setup script is dot-sourced with -LoadFunctionsOnly, which defines every
# helper without executing the provisioning steps. The font helpers accept
# explicit -FontDirectory / -RegistryPath so the tests never touch the real
# user font directory or the real font registry key.
#

$scriptPath = Join-Path $PSScriptRoot '..\Setup-CatppuccinPowerShell.ps1'
$repoRoot = Split-Path -Parent $PSScriptRoot
$bundledArchive = Join-Path $repoRoot 'assets\fonts\FiraCode.zip'

. $scriptPath -LoadFunctionsOnly

# The setup script turns on StrictMode for itself; keep it off for test code.
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$TestRegistryRoot = 'HKCU:\Software\CatppuccinPowerShellTests'

function New-TestDirectory {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("CatppuccinTests-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-TestDirectory {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-TestRegistryKey {
    $path = Join-Path $TestRegistryRoot ([guid]::NewGuid().ToString('N'))
    New-Item -Path $path -Force | Out-Null
    return $path
}

# Pester 3.4 (the version that ships with Windows) cannot detect exceptions
# under PowerShell 7 - its `Should Throw` silently never matches. Assert on the
# thrown message instead: non-empty means it threw.
function Get-ThrownMessage {
    param([Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action | Out-Null
        return $null
    }
    catch {
        return $_.Exception.Message
    }
}

function New-TestFile {
    param([string]$Path, [int]$Size, [byte]$Fill = 0)
    $bytes = New-Object byte[] $Size
    if ($Fill -ne 0) {
        for ($i = 0; $i -lt $Size; $i++) { $bytes[$i] = $Fill }
    }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

# Opens a file the way the Windows font loader does: the bytes stay mapped into
# memory (which blocks overwriting it) but the name can still be renamed.
function Open-MappedFile {
    param([string]$Path)
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', ([System.IO.FileShare]'ReadWrite, Delete'))
    return [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile(
        $stream, [NullString]::Value, 0,
        [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read,
        [System.IO.HandleInheritability]::None, $false)
}

function Get-SampleFontPath {
    param([string]$Directory, [string]$EntryName = 'FiraCodeNerdFont-Regular.ttf')

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($bundledArchive)
    try {
        $entry = $zip.Entries | Where-Object { $_.Name -eq $EntryName } | Select-Object -First 1
        if (-not $entry) { throw "Entry '$EntryName' not found in $bundledArchive" }
        $target = Join-Path $Directory $EntryName
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        return $target
    }
    finally { $zip.Dispose() }
}

Describe 'Script structure' {
    $content = Get-Content -Raw -LiteralPath $scriptPath

    It 'parses without syntax errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should Be 0
    }

    It 'defines its helpers without running the provisioning steps when dot-sourced' {
        (Get-Command Install-BundledNerdFont -CommandType Function) | Should Not BeNullOrEmpty
        (Get-Command Copy-FontFile -CommandType Function) | Should Not BeNullOrEmpty
        (Get-Command Invoke-SetupStep -CommandType Function) | Should Not BeNullOrEmpty
    }

    It 'installs the repository-bundled FiraCode Nerd Font instead of downloading it' {
        $content | Should Match 'function Install-BundledNerdFont'
        $content | Should Match 'assets[\\/]fonts[\\/]FiraCode\.zip'
        $content | Should Match 'Install-BundledNerdFont -ArchivePath'
        $content | Should Not Match 'omp font install'
    }

    It 'installs WinFetch and configures the bundled Catppuccin Windows image' {
        $content | Should Match 'function Ensure-WinFetch'
        $content | Should Match "Install-Script -Name 'winfetch'"
        $content | Should Match 'function Configure-WinFetch'
        $content | Should Match 'assets[\\/]images[\\/]windows-catppuccin\.png'
        $content | Should Match 'windows-catppuccin\.png'
    }
}

Describe 'Get-FontDisplayName' {
    $dir = New-TestDirectory

    It 'reads the full font name out of the TrueType name table' {
        $font = Get-SampleFontPath -Directory $dir
        Get-FontDisplayName -Path $font | Should Match 'FiraCode Nerd Font'
    }

    It 'distinguishes the Mono variant from the proportional one' {
        $mono = Get-SampleFontPath -Directory $dir -EntryName 'FiraCodeNerdFontMono-Regular.ttf'
        $propo = Get-SampleFontPath -Directory $dir -EntryName 'FiraCodeNerdFontPropo-Regular.ttf'
        (Get-FontDisplayName -Path $mono) | Should Not Be (Get-FontDisplayName -Path $propo)
    }

    It 'never returns the mangled "Nerd FontMono" name the old regex produced' {
        $mono = Get-SampleFontPath -Directory $dir -EntryName 'FiraCodeNerdFontMono-Bold.ttf'
        Get-FontDisplayName -Path $mono | Should Not Match 'Nerd FontMono'
    }

    It 'falls back to the file base name when the file is not a font' {
        $bogus = Join-Path $dir 'NotAFont.ttf'
        New-TestFile -Path $bogus -Size 64
        Get-FontDisplayName -Path $bogus | Should Be 'NotAFont'
    }

    It 'falls back to the file base name when the file does not exist' {
        Get-FontDisplayName -Path (Join-Path $dir 'Missing.ttf') | Should Be 'Missing'
    }

    Remove-TestDirectory $dir
}

Describe 'Test-FileContentEqual' {
    $dir = New-TestDirectory
    $a = Join-Path $dir 'a.bin'
    $b = Join-Path $dir 'b.bin'
    $c = Join-Path $dir 'c.bin'

    New-TestFile -Path $a -Size 1024 -Fill 7
    New-TestFile -Path $b -Size 1024 -Fill 7
    New-TestFile -Path $c -Size 1024 -Fill 9

    It 'reports identical files as equal' {
        Test-FileContentEqual -ReferencePath $a -DifferencePath $b | Should Be $true
    }

    It 'reports same-size files with different bytes as different' {
        Test-FileContentEqual -ReferencePath $a -DifferencePath $c | Should Be $false
    }

    It 'reports different sizes as different' {
        $d = Join-Path $dir 'd.bin'
        New-TestFile -Path $d -Size 2048 -Fill 7
        Test-FileContentEqual -ReferencePath $a -DifferencePath $d | Should Be $false
    }

    It 'reports a missing file as different' {
        Test-FileContentEqual -ReferencePath $a -DifferencePath (Join-Path $dir 'nope.bin') | Should Be $false
    }

    Remove-TestDirectory $dir
}

Describe 'Copy-FontFile' {
    $dir = New-TestDirectory
    $source = Join-Path $dir 'source.ttf'
    New-TestFile -Path $source -Size 2048 -Fill 3

    It 'copies when the destination does not exist' {
        $dest = Join-Path $dir 'new.ttf'
        (Copy-FontFile -SourcePath $source -DestinationPath $dest).Status | Should Be 'Copied'
        (Get-Item -LiteralPath $dest).Length | Should Be 2048
    }

    It 'reports UpToDate and leaves an identical destination untouched' {
        $dest = Join-Path $dir 'same.ttf'
        Copy-Item -LiteralPath $source -Destination $dest -Force
        $before = (Get-Item -LiteralPath $dest).LastWriteTimeUtc
        Start-Sleep -Milliseconds 50
        (Copy-FontFile -SourcePath $source -DestinationPath $dest).Status | Should Be 'UpToDate'
        (Get-Item -LiteralPath $dest).LastWriteTimeUtc | Should Be $before
    }

    It 'replaces a destination whose contents differ' {
        $dest = Join-Path $dir 'stale.ttf'
        New-TestFile -Path $dest -Size 512 -Fill 1
        (Copy-FontFile -SourcePath $source -DestinationPath $dest).Status | Should Be 'Replaced'
        (Get-Item -LiteralPath $dest).Length | Should Be 2048
    }

    # Regression test for the reported failure:
    #   "The requested operation cannot be performed on a file with a
    #    user-mapped section open."
    It 'replaces a destination that has an open user-mapped section' {
        $dest = Join-Path $dir 'mapped.ttf'
        New-TestFile -Path $dest -Size 512 -Fill 1
        $map = Open-MappedFile -Path $dest
        try {
            # Prove the naive overwrite really does fail in this situation.
            Get-ThrownMessage { Copy-Item -LiteralPath $source -Destination $dest -Force -ErrorAction Stop } |
                Should Match 'user-mapped section'

            $result = Copy-FontFile -SourcePath $source -DestinationPath $dest
            $result.Status | Should Be 'Replaced'
            (Get-Item -LiteralPath $dest).Length | Should Be 2048
        }
        finally { $map.Dispose() }
    }

    It 'reports Failed instead of throwing when the destination cannot be replaced at all' {
        $dest = Join-Path $dir 'locked.ttf'
        New-TestFile -Path $dest -Size 512 -Fill 1
        # FileShare.Read denies both overwriting and renaming.
        $stream = [System.IO.File]::Open($dest, 'Open', 'Read', 'Read')
        try {
            $result = Copy-FontFile -SourcePath $source -DestinationPath $dest -MaxAttempts 2 -RetryDelayMilliseconds 20
            $result.Status | Should Be 'Failed'
            $result.Message | Should Not BeNullOrEmpty
        }
        finally { $stream.Dispose() }
    }

    It 'throws when the source file is missing' {
        Get-ThrownMessage { Copy-FontFile -SourcePath (Join-Path $dir 'ghost.ttf') -DestinationPath (Join-Path $dir 'out.ttf') } |
            Should Match 'Source font file was not found'
    }

    Remove-TestDirectory $dir
}

Describe 'Install-BundledNerdFont' {
    $fontDir = New-TestDirectory
    $regPath = New-TestRegistryKey

    # -SkipSessionRegistration keeps the installer from loading these throwaway
    # fonts into the test process (which would map the files into memory).
    function Invoke-Install {
        param([hashtable]$Extra = @{})
        $arguments = @{
            ArchivePath             = $bundledArchive
            FontDirectory           = $fontDir
            RegistryPath            = $regPath
            SkipSessionRegistration = $true
        }
        foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
        return Install-BundledNerdFont @arguments
    }

    It 'throws a clear error when the bundled archive is missing' {
        Get-ThrownMessage {
            Install-BundledNerdFont -ArchivePath (Join-Path $fontDir 'nope.zip') -FontDirectory $fontDir `
                -RegistryPath $regPath -SkipSessionRegistration
        } | Should Match 'archive was not found'
    }

    It 'installs every bundled font file and registers each one' {
        $result = Invoke-Install

        $result.Total | Should Be 18
        @($result.Failed).Count | Should Be 0
        @(Get-ChildItem -LiteralPath $fontDir -Filter '*.ttf').Count | Should Be 18

        @((Get-ItemProperty -Path $regPath).PSObject.Properties |
            Where-Object { $_.Name -like '*FiraCode*' }).Count | Should Be 18
    }

    It 'registers readable face names ending in (TrueType)' {
        $names = @((Get-ItemProperty -Path $regPath).PSObject.Properties |
            Where-Object { $_.Name -like '*FiraCode*' } | ForEach-Object { $_.Name })
        ($names | Where-Object { $_ -notlike '*(TrueType)' }) | Should BeNullOrEmpty
        ($names | Where-Object { $_ -like '*Nerd Font*' }) | Should Not BeNullOrEmpty
    }

    It 'registers full file paths so per-user fonts survive a reboot' {
        # A bare file name is resolved against C:\Windows\Fonts, so the font
        # disappears after a restart. Per-user fonts need the absolute path.
        $values = @((Get-ItemProperty -Path $regPath).PSObject.Properties |
            Where-Object { $_.Name -like '*FiraCode*' } | ForEach-Object { $_.Value })
        $values.Count | Should Be 18
        ($values | Where-Object { -not [System.IO.Path]::IsPathRooted($_) }) | Should BeNullOrEmpty
        ($values | Where-Object { -not (Test-Path -LiteralPath $_) }) | Should BeNullOrEmpty
    }

    It 'is idempotent: a second run copies nothing and reports everything up to date' {
        $result = Invoke-Install
        $result.UpToDate | Should Be 18
        $result.Installed | Should Be 0
        @($result.Failed).Count | Should Be 0
    }

    It 'repairs a missing registry entry without recopying the font file' {
        $name = @((Get-ItemProperty -Path $regPath).PSObject.Properties |
            Where-Object { $_.Name -like '*FiraCode*' } | ForEach-Object { $_.Name })[0]
        Remove-ItemProperty -Path $regPath -Name $name

        $result = Invoke-Install
        $result.Registered | Should Be 1
        $result.Installed | Should Be 0
        @((Get-ItemProperty -Path $regPath).PSObject.Properties |
            Where-Object { $_.Name -like '*FiraCode*' }).Count | Should Be 18
    }

    It 'replaces an outdated font file that is currently mapped into memory' {
        $target = Join-Path $fontDir 'FiraCodeNerdFont-Bold.ttf'
        $realLength = (Get-Item -LiteralPath $target).Length
        New-TestFile -Path $target -Size 4096 -Fill 2

        $map = Open-MappedFile -Path $target
        try {
            $result = Invoke-Install
            @($result.Failed).Count | Should Be 0
            $result.Installed | Should Be 1
            (Get-Item -LiteralPath $target).Length | Should Be $realLength
        }
        finally { $map.Dispose() }
    }

    It 'reports an unwritable font file without aborting the other 17' {
        $target = Join-Path $fontDir 'FiraCodeNerdFont-Light.ttf'
        New-TestFile -Path $target -Size 4096 -Fill 2
        $stream = [System.IO.File]::Open($target, 'Open', 'Read', 'Read')
        try {
            $result = Invoke-Install -Extra @{ MaxAttempts = 2; RetryDelayMilliseconds = 20 }
            @($result.Failed).Count | Should Be 1
            $result.Total | Should Be 18
        }
        finally { $stream.Dispose() }
    }

    It 'leaves no temporary extraction directory behind' {
        @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'CatppuccinPowerShell-Fonts-*').Count |
            Should Be 0
    }

    It 'cleans up stale replaced-font leftovers on the next run' {
        $leftover = Join-Path $fontDir 'FiraCodeNerdFont-Bold.ttf.catppuccin-stale-deadbeef'
        New-TestFile -Path $leftover -Size 16
        Invoke-Install | Out-Null
        Test-Path -LiteralPath $leftover | Should Be $false
    }

    Remove-TestDirectory $fontDir
    Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-FontInstalled' {
    $fontDir = New-TestDirectory
    $regPath = New-TestRegistryKey

    It 'returns false when the font is neither registered nor on disk' {
        Test-FontInstalled -FaceName 'FiraCode Nerd Font' -FontDirectory $fontDir -RegistryPaths @($regPath) |
            Should Be $false
    }

    It 'detects a font registered in the registry' {
        New-ItemProperty -Path $regPath -Name 'FiraCode Nerd Font Regular (TrueType)' `
            -Value 'FiraCodeNerdFont-Regular.ttf' -PropertyType String -Force | Out-Null
        Test-FontInstalled -FaceName 'FiraCode Nerd Font' -FontDirectory $fontDir -RegistryPaths @($regPath) |
            Should Be $true
    }

    It 'detects a font present on disk but missing from the registry' {
        $emptyReg = New-TestRegistryKey
        New-TestFile -Path (Join-Path $fontDir 'FiraCodeNerdFont-Regular.ttf') -Size 32
        Test-FontInstalled -FaceName 'FiraCode Nerd Font' -FontDirectory $fontDir -RegistryPaths @($emptyReg) |
            Should Be $true
        Remove-Item -Path $emptyReg -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'ignores registry paths that do not exist' {
        Get-ThrownMessage {
            Test-FontInstalled -FaceName 'Nothing' -FontDirectory $fontDir `
                -RegistryPaths @('HKCU:\Software\CatppuccinPowerShellTests\DoesNotExist')
        } | Should BeNullOrEmpty
    }

    Remove-TestDirectory $fontDir
    Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ManagedProfileBlock' {
    $dir = New-TestDirectory
    $block = "$ManagedBlockStart`r`nWrite-Host 'managed'`r`n$ManagedBlockEnd"

    It 'creates the profile and its parent directory when missing' {
        $profilePath = Join-Path $dir 'nested\profile.ps1'
        Set-ManagedProfileBlock -ProfilePath $profilePath -Block $block
        (Get-Content -Raw -LiteralPath $profilePath) | Should Match 'managed'
    }

    It 'preserves content the user wrote outside the managed block' {
        $profilePath = Join-Path $dir 'existing.ps1'
        Set-Content -LiteralPath $profilePath -Value '# my own line' -NoNewline
        Set-ManagedProfileBlock -ProfilePath $profilePath -Block $block
        (Get-Content -Raw -LiteralPath $profilePath) | Should Match '# my own line'
    }

    It 'replaces the managed block instead of appending a second copy' {
        $profilePath = Join-Path $dir 'idempotent.ps1'
        Set-ManagedProfileBlock -ProfilePath $profilePath -Block $block
        $updated = "$ManagedBlockStart`r`nWrite-Host 'updated'`r`n$ManagedBlockEnd"
        Set-ManagedProfileBlock -ProfilePath $profilePath -Block $updated

        $content = Get-Content -Raw -LiteralPath $profilePath
        @([regex]::Matches($content, [regex]::Escape($ManagedBlockStart))).Count | Should Be 1
        $content | Should Match 'updated'
        $content | Should Not Match "Write-Host 'managed'"
    }

    It 'writes UTF-8 without a BOM' {
        $profilePath = Join-Path $dir 'encoding.ps1'
        Set-ManagedProfileBlock -ProfilePath $profilePath -Block $block
        $bytes = [System.IO.File]::ReadAllBytes($profilePath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
    }

    Remove-TestDirectory $dir
}

Describe 'Read-JsoncAsHashtable' {
    $dir = New-TestDirectory

    It 'returns an empty dictionary for a missing file' {
        (Read-JsoncAsHashtable -Path (Join-Path $dir 'missing.json')).Count | Should Be 0
    }

    It 'returns an empty dictionary for an empty file' {
        $path = Join-Path $dir 'empty.json'
        Set-Content -LiteralPath $path -Value '' -NoNewline
        (Read-JsoncAsHashtable -Path $path).Count | Should Be 0
    }

    It 'parses JSONC comments and trailing commas like Windows Terminal does' {
        $path = Join-Path $dir 'settings.json'
        $jsonc = "{`r`n    // a line comment`r`n    ""defaultProfile"": ""{guid}"",`r`n    /* block */`r`n    ""profiles"": { ""list"": [ { ""name"": ""x"" }, ], },`r`n}"
        Set-Content -LiteralPath $path -Value $jsonc
        $settings = Read-JsoncAsHashtable -Path $path
        $settings['defaultProfile'] | Should Be '{guid}'
        $settings['profiles']['list'][0]['name'] | Should Be 'x'
    }

    Remove-TestDirectory $dir
}

Describe 'Backup-File' {
    $dir = New-TestDirectory

    It 'returns nothing when there is no file to back up' {
        Backup-File -Path (Join-Path $dir 'missing.txt') | Should BeNullOrEmpty
    }

    It 'creates a timestamped copy alongside the original' {
        $path = Join-Path $dir 'file.txt'
        Set-Content -LiteralPath $path -Value 'original'
        $backup = Backup-File -Path $path
        $backup | Should Match 'file\.txt\.backup-\d{8}-\d{6}'
        (Get-Content -Raw -LiteralPath $backup).Trim() | Should Be 'original'
    }

    Remove-TestDirectory $dir
}

Describe 'Invoke-SetupStep' {
    It 'runs the action and records no failure' {
        Reset-SetupFailures
        Invoke-SetupStep -Name 'ok' -Action { $null = 1 + 1 }
        @(Get-SetupFailures).Count | Should Be 0
    }

    It 'records a non-critical failure and keeps going' {
        Reset-SetupFailures
        Get-ThrownMessage { Invoke-SetupStep -Name 'optional' -Action { throw 'boom' } } | Should BeNullOrEmpty
        @(Get-SetupFailures).Count | Should Be 1
        @(Get-SetupFailures)[0] | Should Match 'optional'
        @(Get-SetupFailures)[0] | Should Match 'boom'
    }

    It 'rethrows a critical failure' {
        Reset-SetupFailures
        Get-ThrownMessage { Invoke-SetupStep -Name 'required' -Action { throw 'fatal' } -Critical } | Should Match 'fatal'
    }

    It 'does not record a critical failure it rethrew' {
        Reset-SetupFailures
        Get-ThrownMessage { Invoke-SetupStep -Name 'required' -Action { throw 'fatal' } -Critical } | Out-Null
        @(Get-SetupFailures).Count | Should Be 0
    }

    It 'passes the action output back to the caller' {
        Reset-SetupFailures
        $value = Invoke-SetupStep -Name 'output' -Action { 'produced' }
        $value | Should Be 'produced'
    }

    It 'returns nothing when a non-critical action fails' {
        Reset-SetupFailures
        $value = Invoke-SetupStep -Name 'broken' -Action { throw 'nope' }
        $value | Should BeNullOrEmpty
    }
}

Describe 'Test cleanup' {
    It 'removes the test registry root' {
        if (Test-Path $TestRegistryRoot) {
            Remove-Item -Path $TestRegistryRoot -Recurse -Force
        }
        Test-Path $TestRegistryRoot | Should Be $false
    }
}
