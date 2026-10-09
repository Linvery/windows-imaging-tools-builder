[CmdletBinding()]
param([string]$VirtioIsoPath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Project.Common.ps1')
Assert-PowerShell51
. (Join-Path $root 'scripts\Configuration.Common.ps1')
$tar=Get-Command tar.exe -ErrorAction Stop
$fixture=Join-Path $root ('local\virtio resource tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
$fixtureInput=Join-Path $fixture 'input'
New-Item -ItemType Directory -Path $fixtureInput -Force|Out-Null
$member=Join-Path $fixtureInput 'virtio-win-guest-tools.exe'
[IO.File]::WriteAllBytes($member,[byte[]]@(0,1,2,128,255,0,13,10))
$originalHash=(Get-FileHash -LiteralPath $member -Algorithm SHA256).Hash
$settings=[PSCustomObject]@{ProjectRoot=$fixture;AssetsRoot=(Join-Path $fixture 'assets')}
$archive=Join-Path $fixture 'resource fixture.iso'
& $tar.Source -cf $archive -C $fixtureInput -- 'virtio-win-guest-tools.exe'
if($LASTEXITCODE -ne 0){throw 'Could not create extraction fixture.'}
$prepared=Initialize-VirtioGuestTools -Settings $settings -VirtioIsoPath $archive -RefreshFromIso
if((Get-FileHash -LiteralPath $prepared -Algorithm SHA256).Hash -ne $originalHash){throw 'Binary extraction changed the installer bytes.'}
$wrong=Join-Path $fixtureInput 'renamed-guest-tools.exe'
Copy-Item -LiteralPath $member -Destination $wrong
$rejected=$false
try{Assert-ImagePackage -Path $wrong -Package (Get-SelectedImagePackages -SkipChrome -SkipVSCode)}catch{if($_.Exception.Message -notmatch 'filename must be'){throw};$rejected=$true}
if(-not$rejected){throw 'A renamed VirtIO installer was accepted.'}
$missing=Join-Path $fixture 'missing member.iso'
[IO.File]::WriteAllText((Join-Path $fixtureInput 'placeholder.txt'),'No installer.')
& $tar.Source -cf $missing -C $fixtureInput -- 'placeholder.txt'
if($LASTEXITCODE -ne 0){throw 'Could not create missing-member fixture.'}
$rejected=$false
try{Initialize-VirtioGuestTools -Settings $settings -VirtioIsoPath $missing -RefreshFromIso|Out-Null}catch{$rejected=$true}
if(-not$rejected -or (Get-FileHash -LiteralPath $prepared).Hash -ne $originalHash){throw 'A failed extraction was accepted or changed the cached installer.'}
& {
    function Expand-VirtioGuestTools { throw 'A correctly named cached installer must not be extracted again.' }
    function Get-AuthenticodeSignature { throw 'VirtIO should use filename validation only.' }
    Initialize-VirtioGuestTools -Settings $settings -VirtioIsoPath $archive|Out-Null
}
if(@(Get-ChildItem -LiteralPath (Join-Path $fixture 'local\virtio-extract') -Directory).Count){throw 'Temporary extraction directories were left behind.'}
$actual='not_requested'
$configuration='not_requested'
if($VirtioIsoPath){
    $realSettings=[PSCustomObject]@{ProjectRoot=$fixture;AssetsRoot=(Join-Path $fixture 'real assets')}
    $actualInstaller=Initialize-VirtioGuestTools -Settings $realSettings -VirtioIsoPath $VirtioIsoPath -RefreshFromIso
    $actual=(Get-FileHash -LiteralPath $actualInstaller -Algorithm SHA256).Hash
    # Exercise the normal config entry with no standalone guest-tools file.
    foreach($directory in @('scripts','config','resources','local')){New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force|Out-Null}
    foreach($name in @('New-ImageConfig.ps1','scripts\Project.Common.ps1','scripts\Configuration.Common.ps1','scripts\Package.Validation.ps1','scripts\ProductKeys.Common.ps1','scripts\Software.Selection.ps1','config\Kms.ClientKeys.psd1','config\image.example.ini')){Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $fixture $name)}
    New-Item -ItemType Directory -Path (Join-Path $realSettings.AssetsRoot 'iso') -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'local\settings.json'),($realSettings|ConvertTo-Json))
    $wim=Join-Path $fixtureInput 'config-only.wim'
    [IO.File]::WriteAllText($wim,'Config fixture; never used to create a disk.')
    Move-Item -LiteralPath $actualInstaller -Destination ($actualInstaller+'.validated-copy')
    $config=& (Join-Path $fixture 'New-ImageConfig.ps1') -WimPath $wim -VirtioIsoPath $VirtioIsoPath -OutputPath (Join-Path $realSettings.AssetsRoot 'output\config-only.qcow2') -SkipChrome -SkipVSCode
    if((Get-FileHash -LiteralPath (Join-Path $config.StagedResources 'virtio-win-guest-tools.exe')).Hash -ne $actual){throw 'Config generation did not stage the validated ISO installer.'}
    $configuration='passed; installer extracted automatically'
}
[PSCustomObject]@{BinaryExtraction='passed';MissingMember='rejected; original preserved';WrongFilename='rejected';VirtioSignature='not required';CacheReuse='passed';Cleanup='passed';ActualIsoInstallerSHA256=$actual;ConfigGeneration=$configuration}
# The expected missing-member failure leaves tar's nonzero native exit code behind.
# Report the completed assertions as successful to callers such as GitHub Actions.
exit 0
