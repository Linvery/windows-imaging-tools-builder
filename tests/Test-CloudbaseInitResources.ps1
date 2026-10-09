[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Project.Common.ps1')
Assert-PowerShell51
. (Join-Path $root 'scripts\CloudbaseInit.Resources.ps1')
function Assert-CloudbaseTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-CloudbaseFailure {
    param([scriptblock]$Action,[string]$Pattern)
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true; if ($_.Exception.Message -notmatch $Pattern) { throw } }
    if (-not $failed) { throw ('Expected failure: '+$Pattern) }
}
function New-CloudbaseTestMsi {
    param([string]$Path,[string]$Product='Cloudbase-Init 1.1.8',[string]$Platform='x64')
    $installer=$null;$database=$null;$view=$null;$summary=$null
    try {
        $installer=New-Object -ComObject WindowsInstaller.Installer
        $database=$installer.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$installer,@($Path,3))
        foreach ($sql in @('CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(0) LOCALIZABLE PRIMARY KEY `Property`)',('INSERT INTO `Property` (`Property`, `Value`) VALUES (''ProductName'', '''+$Product+''')'))) {
            $view=$database.GetType().InvokeMember('OpenView','InvokeMethod',$null,$database,@($sql))
            $view.GetType().InvokeMember('Execute','InvokeMethod',$null,$view,$null) | Out-Null
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null
            $view=$null
        }
        $summary=$database.GetType().InvokeMember('SummaryInformation','GetProperty',$null,$database,@(1))
        $summary.GetType().InvokeMember('Property','SetProperty',$null,$summary,@(7,($Platform+';1033'))) | Out-Null
        $summary.GetType().InvokeMember('Persist','InvokeMethod',$null,$summary,$null) | Out-Null
        $database.GetType().InvokeMember('Commit','InvokeMethod',$null,$database,$null) | Out-Null
    } finally {
        foreach ($comObject in @($summary,$view,$database,$installer)) {
            if ($null -ne $comObject) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) | Out-Null }
        }
    }
}
$fixture=Join-Path $root ('local\cloudbase cache tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$valid=Join-Path $fixture 'valid.msi'
$x86=Join-Path $fixture 'x86.msi'
$wrong=Join-Path $fixture 'wrong.msi'
$html=Join-Path $fixture 'error page.msi'
New-CloudbaseTestMsi -Path $valid
New-CloudbaseTestMsi -Path $x86 -Platform 'Intel'
New-CloudbaseTestMsi -Path $wrong -Product 'Other installer'
[IO.File]::WriteAllText($html,'<html>Download error</html>')
Assert-PveCloudbaseInitInstaller -Path $valid -OsArch AMD64
Assert-PveCloudbaseInitInstaller -Path $x86 -OsArch i386
Assert-CloudbaseFailure { Assert-PveCloudbaseInitInstaller -Path $wrong } 'Unexpected MSI product'
Assert-CloudbaseFailure { Assert-PveCloudbaseInitInstaller -Path $html } 'not a valid matching MSI'
Assert-CloudbaseFailure { Assert-PveCloudbaseInitInstaller -Path $x86 } 'Incorrect MSI architecture'
$assets=Join-Path $fixture 'chosen assets $literal'
& {
    $script:downloadCalls=0
    $script:downloadMode='valid'
    function Invoke-PveCloudbaseInitDownload {
        param($Uri,$Destination)
        $script:downloadCalls++
        if ($script:downloadMode -eq 'failure') { [IO.File]::WriteAllText($Destination,'partial download'); throw 'Simulated download failure.' }
        if ($script:downloadMode -eq 'html') { Copy-Item -LiteralPath $html -Destination $Destination; return }
        $source=$valid
        if ($Uri -like '*_x86.msi') { $source=$x86 }
        Copy-Item -LiteralPath $source -Destination $Destination
    }
    $cache=Get-PveCloudbaseInitCachePath -AssetsRoot $assets
    $script:downloadMode='failure'
    Assert-CloudbaseFailure { Initialize-PveCloudbaseInitInstaller -AssetsRoot $assets } 'Simulated download failure'
    Assert-CloudbaseTest (-not (Test-Path -LiteralPath $cache)) 'A failed download was published as a cache.'
    $script:downloadMode='valid'
    $first=Initialize-PveCloudbaseInitInstaller -AssetsRoot $assets
    Assert-CloudbaseTest ($first -eq $cache) 'Cache path differs from the selected asset directory.'
    $originalHash=(Get-FileHash -LiteralPath $valid).Hash
    Assert-CloudbaseTest ((Get-FileHash -LiteralPath $cache).Hash -eq $originalHash) 'Caching changed the MSI bytes.'
    $before=$script:downloadCalls
    $script:downloadMode='failure'
    $second=Initialize-PveCloudbaseInitInstaller -AssetsRoot $assets
    Assert-CloudbaseTest ($second -eq $cache -and $script:downloadCalls -eq $before) 'A valid cache required network access.'
    [IO.File]::WriteAllText($cache,'damaged cache')
    $script:downloadMode='html'
    Assert-CloudbaseFailure { Initialize-PveCloudbaseInitInstaller -AssetsRoot $assets } 'not a valid matching MSI'
    Assert-CloudbaseTest ([IO.File]::ReadAllText($cache) -eq 'damaged cache') 'An invalid download overwrote the previous file.'
    $script:downloadMode='valid'
    Initialize-PveCloudbaseInitInstaller -AssetsRoot $assets | Out-Null
    Assert-CloudbaseTest ((Get-FileHash -LiteralPath $cache).Hash -eq $originalHash) 'The corrupt cache was not repaired.'
    $beta=Initialize-PveCloudbaseInitInstaller -AssetsRoot $assets -BetaRelease
    $otherArch=Initialize-PveCloudbaseInitInstaller -AssetsRoot $assets -OsArch i386
    Assert-CloudbaseTest ($beta -ne $cache -and $otherArch -ne $cache -and $otherArch -ne $beta) 'Architecture/release caches overlap.'
    Assert-CloudbaseTest (-not @(Get-ChildItem -LiteralPath (Split-Path -Parent $cache) -Filter '*.partial.msi').Count) 'Partial downloads were left behind.'
}
$settings=[PSCustomObject]@{ProjectRoot=$root;AssetsRoot=$assets;UpstreamRoot=(Join-Path $root 'vendor\windows-imaging-tools');QemuManifestPath=(Join-Path $fixture 'unused-tool-manifest.json')}
. (Join-Path $root 'scripts\Import-ImagingTools.ps1') -Settings $settings
$module=Get-Module WinImageBuilder
& $module {
    function script:Invoke-PveCloudbaseInitDownload { throw 'Image staging must reuse the validated cache.' }
} | Out-Null
foreach ($mode in @('generated','legacy','custom')) {
    $imageResources=Join-Path $fixture ('image '+$mode+'\UnattendResources')
    New-Item -ItemType Directory -Path $imageResources -Force | Out-Null
    $msi=''
    if ($mode -eq 'generated') { $msi=Get-PveCloudbaseInitCachePath -AssetsRoot $assets }
    if ($mode -eq 'custom') { $msi=$valid }
    & $module {
        param($Resources,$Msi,$Config)
        Download-CloudbaseInit -resourcesDir $Resources -osArch AMD64 -MsiPath $Msi -CloudbaseInitConfigPath $Config
    } $imageResources $msi (Join-Path $root 'config\cloudbase-init.conf')
    Assert-CloudbaseTest ((Get-FileHash -LiteralPath (Join-Path $imageResources 'CloudbaseInit.msi')).Hash -eq (Get-FileHash -LiteralPath $valid).Hash) ('Image MSI staging failed: '+$mode)
    Assert-CloudbaseTest ((Get-FileHash -LiteralPath (Join-Path $imageResources 'cloudbase-init.conf')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $root 'config\cloudbase-init.conf')).Hash) 'Cloudbase-Init configuration staging changed.'
}
Assert-CloudbaseFailure {
    & $module { param($Resources,$Missing); Download-CloudbaseInit -resourcesDir $Resources -osArch AMD64 -MsiPath $Missing } $imageResources (Join-Path $fixture 'missing custom.msi')
} 'does not exist'
Assert-CloudbaseTest (Test-Path -LiteralPath (Get-PveCloudbaseInitCachePath -AssetsRoot $assets)) 'Staging removed the host cache.'
[PSCustomObject]@{MsiValidation='passed';FailedDownload='not published';CacheReuse='offline';CorruptCache='repaired';InvalidDownload='previous file preserved';ArchitectureAndRelease='separate';PartialCleanup='passed';ImageStaging='generated, legacy and custom';PathsWithSpaces='passed'}
