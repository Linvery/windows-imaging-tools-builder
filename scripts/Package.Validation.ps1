function Get-SelectedImagePackages {
    param([switch]$SkipChrome, [switch]$SkipVSCode)
    if (-not $SkipChrome) {
        [PSCustomObject]@{Name='Chrome';File='chrome-enterprise64.msi';Publishers=@('Google LLC','Google Inc');Validation='Signature'}
    }
    if (-not $SkipVSCode) {
        [PSCustomObject]@{Name='VSCode';File='VSCodeSetup-x64.exe';Publishers=@('Microsoft Corporation');Validation='Signature'}
    }
    [PSCustomObject]@{Name='VirtIO';File='virtio-win-guest-tools.exe';Publishers=@();Validation='FileName'}
}

function Assert-ImagePackage {
    param([string]$Path, $Package)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required installer is missing: $Path" }
    if ($Package.Validation -eq 'FileName') {
        if ([IO.Path]::GetFileName($Path) -ine $Package.File) { throw ('Installer filename must be ' + $Package.File) }
        return
    }
    if ($Package.Validation -ne 'Signature') { throw 'Unknown installer validation rule.' }
    if ([IO.Path]::GetExtension($Path) -ine [IO.Path]::GetExtension($Package.File)) { throw ('Incorrect installer file type: ' + $Package.Name) }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate) {
        throw ('Installer signature is not valid: ' + $Package.Name + ' (' + $signature.Status + ')')
    }
    $publisher = $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ($publisher -notin $Package.Publishers) { throw ('Unexpected installer publisher: ' + $publisher + '; expected ' + ($Package.Publishers -join ' / ')) }
}

function Find-ImagePackageInstaller {
    param($Package, [string[]]$Directories)
    foreach ($directory in $Directories) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        $candidates = @(Get-ChildItem -LiteralPath $directory -File | Where-Object {
            $_.Name -ieq $Package.File -or
            ($Package.Name -eq 'Chrome' -and $_.Name -like '*chrome*.msi') -or
            ($Package.Name -eq 'VSCode' -and $_.Name -like 'VSCodeSetup*.exe')
        } | Sort-Object LastWriteTime -Descending)
        foreach ($candidate in $candidates) {
            try { Assert-ImagePackage -Path $candidate.FullName -Package $Package; return $candidate.FullName } catch {}
        }
    }
}
