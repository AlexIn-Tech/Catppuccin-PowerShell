$scriptPath = Join-Path $PSScriptRoot '..\Setup-CatppuccinPowerShell.ps1'

Describe 'Bundled Nerd Font installation' {
    It 'installs the repository-bundled FiraCode Nerd Font instead of downloading it' {
        $content = Get-Content -Raw -LiteralPath $scriptPath

        $content | Should Match 'function Install-BundledNerdFont'
        $content | Should Match 'assets[\\/]fonts[\\/]FiraCode\.zip'
        $content | Should Match 'Install-BundledNerdFont -ArchivePath'
        $content | Should Not Match 'omp font install'
    }
}

Describe 'WinFetch setup' {
    It 'installs WinFetch and configures the bundled Catppuccin Windows image' {
        $content = Get-Content -Raw -LiteralPath $scriptPath

        $content | Should Match 'function Ensure-WinFetch'
        $content | Should Match "Install-Script -Name 'winfetch'"
        $content | Should Match 'function Configure-WinFetch'
        $content | Should Match 'assets[\\/]images[\\/]windows-catppuccin\.png'
        $content | Should Match 'windows-catppuccin\.png'
    }
}
