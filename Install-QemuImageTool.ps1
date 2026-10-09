[CmdletBinding()]
param([string]$InstallerPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'scripts\Project.Common.ps1')
Assert-PowerShell51
$settings=Get-ProjectSettings
$project=Get-BuildDependencies
$toolRoot=Join-Path $settings.AssetsRoot ('tools\qemu-img-'+$project.Qemu.Version)
New-Item -ItemType Directory -Path $toolRoot -Force|Out-Null
if(-not$InstallerPath){
    $InstallerPath=Join-Path $toolRoot 'qemu-installer.exe'
    Invoke-WebRequest -Uri $project.Qemu.InstallerUrl -OutFile $InstallerPath -UseBasicParsing
}
if((Get-FileHash -Algorithm SHA512 -LiteralPath $InstallerPath).Hash -ne $project.Qemu.SHA512){throw 'QEMU package hash mismatch.'}
$sevenZipRoot=Join-Path $ProjectRoot 'local\7zip-extract'
New-Item -ItemType Directory -Path $sevenZipRoot -Force|Out-Null
$msi=Join-Path $sevenZipRoot '7zip.msi'
if(-not(Test-Path -LiteralPath $msi)){Invoke-WebRequest -Uri $project.Qemu.SevenZipMsiUrl -OutFile $msi -UseBasicParsing}
if((Get-FileHash -Algorithm SHA256 -LiteralPath $msi).Hash -ne $project.Qemu.SevenZipMsiSHA256){throw '7-Zip package hash mismatch.'}
$unpack=Join-Path $sevenZipRoot 'files'
& (Join-Path $ProjectRoot 'scripts\Expand-ToolMsi.ps1') -Package $msi -Destination $unpack|Out-Null
$bin=Join-Path $toolRoot 'bin'
& (Join-Path $unpack '7z.exe') e $InstallerPath 'qemu-img.exe' '*.dll' 'COPYING*' 'LICENSE*' ('-o'+$bin) -y|Out-Null
if($LASTEXITCODE -ne 0){throw 'QEMU extraction failed.'}
$exe=Join-Path $bin 'qemu-img.exe'
if((Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash -ne $project.Qemu.ExecutableSHA256){throw 'Extracted qemu-img hash mismatch.'}
& $exe --version
if($LASTEXITCODE -ne 0){throw 'qemu-img cannot start.'}
$manifest=[ordered]@{Version=$project.Qemu.Version;ExecutablePath=$exe;ExecutableSha256=$project.Qemu.ExecutableSHA256;InstallerSource=$project.Qemu.InstallerUrl;InstallerSha512=$project.Qemu.SHA512;PublishedHashVerified=$true;Extraction='Portable files only; no host software installation.'}
[IO.File]::WriteAllText($settings.QemuManifestPath,($manifest|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
[PSCustomObject]@{Version=$manifest.Version;ExecutablePath=$exe;Manifest=$settings.QemuManifestPath}
