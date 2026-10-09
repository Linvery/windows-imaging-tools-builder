[CmdletBinding()]
param([string]$ChromePath,[string]$VSCodePath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Project.Common.ps1')
Assert-PowerShell51
. (Join-Path $root 'scripts\Package.Validation.ps1')
$fixture=Join-Path $root ('local\signature tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
function Assert-SignatureThrows {
    param([scriptblock]$Action,[string]$Pattern)
    try { & $Action; throw 'Expected validation to reject the installer.' }
    catch { if ($_.Exception.Message -notmatch $Pattern) { throw } }
}
& {
    $script:testSignatureStatus='Valid'
    $script:testPublisher='Google LLC'
    $script:signatureCalls=0
    function Get-AuthenticodeSignature {
        param($LiteralPath)
        $script:signatureCalls++
        $certificate=[PSCustomObject]@{Publisher=$script:testPublisher}
        $certificate | Add-Member -MemberType ScriptMethod -Name GetNameInfo -Value {param($Type,$ForIssuer) $this.Publisher}
        [PSCustomObject]@{Status=$script:testSignatureStatus;SignerCertificate=$certificate}
    }
    $chrome=Get-SelectedImagePackages -SkipVSCode | Where-Object Name -eq 'Chrome'
    $code=Get-SelectedImagePackages -SkipChrome | Where-Object Name -eq 'VSCode'
    $virtio=Get-SelectedImagePackages -SkipChrome -SkipVSCode
    $msi=Join-Path $fixture 'download with any name.msi'
    $exe=Join-Path $fixture 'new version 999.0 setup.exe'
    [IO.File]::WriteAllText($msi,'Installer fixture; never executed.')
    [IO.File]::WriteAllText($exe,'Installer fixture; never executed.')
    Assert-ImagePackage -Path $msi -Package $chrome
    $script:testPublisher='Google Inc'
    Assert-ImagePackage -Path $msi -Package $chrome
    $script:testPublisher='Microsoft Corporation'
    Assert-ImagePackage -Path $exe -Package $code
    Assert-SignatureThrows { Assert-ImagePackage -Path $msi -Package $chrome } 'Unexpected installer publisher'
    foreach ($status in @('NotSigned','HashMismatch','NotTrusted','UnknownError')) {
        $script:testSignatureStatus=$status
        Assert-SignatureThrows { Assert-ImagePackage -Path $exe -Package $code } 'signature is not valid'
    }
    $script:testSignatureStatus='Valid'
    Assert-SignatureThrows { Assert-ImagePackage -Path $msi -Package $code } 'file type'
    Assert-SignatureThrows { Assert-ImagePackage -Path (Join-Path $fixture 'missing.exe') -Package $code } 'Required installer'
    $guestTools=Join-Path $fixture 'virtio-win-guest-tools.exe'
    [IO.File]::WriteAllText($guestTools,'Unsigned fixture with arbitrary version/content.')
    $callsBefore=$script:signatureCalls
    Assert-ImagePackage -Path $guestTools -Package $virtio
    if ($script:signatureCalls -ne $callsBefore) { throw 'VirtIO unexpectedly requested signature validation.' }
    Assert-SignatureThrows { Assert-ImagePackage -Path $exe -Package $virtio } 'filename must be'
}
$realChecks=@()
foreach ($entry in @(@{Name='Chrome';Path=$ChromePath},@{Name='VSCode';Path=$VSCodePath})) {
    if (-not $entry.Path) { continue }
    $package=Get-SelectedImagePackages | Where-Object Name -eq $entry.Name
    Assert-ImagePackage -Path $entry.Path -Package $package
    # Renaming a download must not affect its signature or acceptance.
    $copy=Join-Path $fixture ('arbitrary downloaded name '+$entry.Name+[IO.Path]::GetExtension($entry.Path))
    Copy-Item -LiteralPath $entry.Path -Destination $copy
    Assert-ImagePackage -Path $copy -Package $package
    $stream=[IO.File]::Open($copy,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite)
    try {
        $stream.Position=256
        $value=$stream.ReadByte()
        $stream.Position=256
        $stream.WriteByte([byte]($value -bxor 1))
    } finally { $stream.Dispose() }
    Assert-SignatureThrows { Assert-ImagePackage -Path $copy -Package $package } 'signature is not valid'
    $realChecks+=$entry.Name
}
[PSCustomObject]@{SignaturePolicy='passed';InvalidSignatures='rejected';WrongPublisher='rejected';ArbitraryFilename='passed';Virtio='exact filename only';RealSignedInstallers=($realChecks -join ', ');Fixture=$fixture}
