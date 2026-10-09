[CmdletBinding()]
param([string]$AssetsRoot,[string]$GitPath,[switch]$SkipSubmodules)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
. (Join-Path $root 'scripts\Project.Common.ps1')
if(-not$GitPath){$git=Get-Command git.exe -ErrorAction SilentlyContinue;if(-not$git){throw 'Git for Windows is required.'};$GitPath=$git.Source}
$manifest=Get-BuildDependencies
if(-not$SkipSubmodules){
    & $GitPath -c core.longpaths=true -C $root submodule update --init --recursive
    if($LASTEXITCODE -ne 0){throw 'Submodule initialization failed.'}
}
$upstream=Join-Path $root 'vendor\windows-imaging-tools'
if(-not(Test-Path -LiteralPath (Join-Path $upstream 'WinImageBuilder.psm1'))){throw 'Upstream submodule is absent; initialize submodules first.'}
$revision=(& $GitPath -C $upstream rev-parse HEAD)-join ''
if($revision -ne $manifest.UpstreamCommit){throw 'Submodule revision does not match the pinned project version.'}
if(-not$AssetsRoot){$AssetsRoot=Join-Path $root 'data'}
$assets=[IO.Path]::GetFullPath($AssetsRoot)
foreach($name in @('iso','custom-resources','tools','output','logs','work','archive')){New-Item -ItemType Directory -Path (Join-Path $assets $name) -Force|Out-Null}
$local=Join-Path $root 'local'
New-Item -ItemType Directory -Path $local -Force|Out-Null
$settings=[ordered]@{ProjectRoot=$root;AssetsRoot=$assets;UpstreamRoot=$upstream;GitPath=$GitPath;QemuManifestPath=(Join-Path $assets ('tools\qemu-img-'+$manifest.Qemu.Version+'\tool-manifest.json'))}
[IO.File]::WriteAllText((Join-Path $local 'settings.json'),($settings|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
[PSCustomObject]@{ProjectRoot=$root;AssetsRoot=$assets;UpstreamCommit=$revision;Initialized=$true}
