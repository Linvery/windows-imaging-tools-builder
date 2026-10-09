$ProjectRoot=Split-Path -Parent $PSScriptRoot
function Get-BuildDependencies {
    return Import-PowerShellDataFile -LiteralPath (Join-Path $ProjectRoot 'scripts\Build.Dependencies.psd1')
}
function Get-ProjectSettings {
    $file=Join-Path $ProjectRoot 'local\settings.json'
    if(-not(Test-Path -LiteralPath $file)){throw 'Run Initialize-Project.ps1 first.'}
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $file|ConvertFrom-Json
}
function Get-ProjectGit {
    $git=Get-Command git.exe -ErrorAction SilentlyContinue
    if($git){return $git.Source}
    throw 'Git for Windows must be available on PATH, or pass GitPath to Initialize-Project.ps1.'
}
function Assert-PowerShell51 {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1){throw 'Use Windows PowerShell 5.1 (powershell.exe).'}
}
function Assert-Administrator {
    $p=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run from an elevated administrator PowerShell.'}
}
