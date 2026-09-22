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
