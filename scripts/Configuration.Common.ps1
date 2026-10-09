function Assert-ConfigValue {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOfAny([char[]]@("`r", "`n", [char]0)) -ge 0) { throw "Invalid configuration value: $Name" }
}
. (Join-Path $PSScriptRoot 'Package.Validation.ps1')
. (Join-Path $PSScriptRoot 'ProductKeys.Common.ps1')
. (Join-Path $PSScriptRoot 'Software.Selection.ps1')
function Get-DefaultImageFileName {
    param([string]$ImageName, [datetime]$Timestamp=(Get-Date))
    Assert-ConfigValue -Value $ImageName -Name 'ImageName'
    if ($ImageName -match '^Windows\s+Server\s+(\d{4})\b') { $prefix = 'WinServer' + $Matches[1] }
    elseif ($ImageName -match '^Windows\s+(\d+(?:\.\d+)?)\b') { $prefix = 'Win' + $Matches[1] }
    else {
        $prefix = $ImageName -replace '[^\p{L}\p{Nd}._-]', ''
        if (-not $prefix) { $prefix = 'Windows' }
    }
    return $prefix + '-' + $Timestamp.ToString('yyyyMMddHHmm', [Globalization.CultureInfo]::InvariantCulture) + '.qcow2'
}
function Find-WindowsInstallerIso {
    param([string]$ProjectRoot,[string]$AssetsRoot)
    foreach($directory in @((Join-Path $ProjectRoot 'data\iso'),(Join-Path $AssetsRoot 'iso'))){
        if(-not(Test-Path -LiteralPath $directory -PathType Container)){continue}
        $candidate=Get-ChildItem -LiteralPath $directory -Filter '*.iso' -File|Where-Object Name -notlike '*virtio*'|Sort-Object Name|Select-Object -First 1
        if($candidate){return $candidate.FullName}
    }
}
function Find-VirtioInstallerIso {
    param([string]$ProjectRoot,[string]$AssetsRoot)
    foreach($directory in @((Join-Path $ProjectRoot 'data\iso'),(Join-Path $AssetsRoot 'iso'))){
        if(-not(Test-Path -LiteralPath $directory -PathType Container)){continue}
        $candidate=Get-ChildItem -LiteralPath $directory -Filter '*virtio*.iso' -File|Sort-Object Name|Select-Object -First 1
        if($candidate){return $candidate.FullName}
    }
}
function Set-ImageConfigValue {
    param([string]$Text, [string]$Key, [string]$Value)
    Assert-ConfigValue -Value $Value -Name $Key
    $pattern = '(?m)^' + [regex]::Escape($Key) + '=.*$'
    if (-not [regex]::IsMatch($Text, $pattern)) { throw "Configuration key not found: $Key" }
    $replacement = $Key + '=' + $Value
    return [regex]::Replace($Text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement })
}
function Expand-VirtioGuestTools {
    param([string]$IsoPath,[string]$DestinationDirectory)
    $member='virtio-win-guest-tools.exe'
    $tar=Get-Command tar.exe -ErrorAction SilentlyContinue
    if($tar){
        $priorErrorAction=$ErrorActionPreference
        try{
            $ErrorActionPreference='Continue'
            $output=@(& $tar.Source -xf $IsoPath -C $DestinationDirectory -- $member 2>&1|ForEach-Object{$_.ToString()})
            $exitCode=$LASTEXITCODE
        }finally{$ErrorActionPreference=$priorErrorAction}
        if($exitCode -ne 0){throw ('Cannot extract VirtIO guest tools from the selected ISO: '+($output -join ' '))}
    }else{
        $mountedHere=$false
        try{
            $image=Get-DiskImage -ImagePath $IsoPath
            if(-not$image.Attached){Mount-DiskImage -ImagePath $IsoPath -StorageType ISO|Out-Null;$mountedHere=$true}
            $volumes=@(Get-DiskImage -ImagePath $IsoPath|Get-Volume|Where-Object DriveLetter)
            if($volumes.Count -ne 1){throw 'Cannot identify the VirtIO ISO volume.'}
            $source=Join-Path ($volumes[0].DriveLetter+':\') $member
            Copy-Item -LiteralPath $source -Destination (Join-Path $DestinationDirectory $member)
        }finally{if($mountedHere){Dismount-DiskImage -ImagePath $IsoPath|Out-Null}}
    }
    $extracted=Join-Path $DestinationDirectory $member
    if(-not(Test-Path -LiteralPath $extracted -PathType Leaf)){throw 'The selected VirtIO ISO does not contain virtio-win-guest-tools.exe.'}
    return $extracted
}
function Initialize-VirtioGuestTools {
    param($Settings,[string]$VirtioIsoPath,[switch]$RefreshFromIso)
    $package=Get-SelectedImagePackages -SkipChrome -SkipVSCode
    $destination=Join-Path $Settings.AssetsRoot ('custom-resources\'+$package.File)
    if(-not$RefreshFromIso){
        try{Assert-ImagePackage -Path $destination -Package $package;return $destination}catch{}
    }
    if(-not(Test-Path -LiteralPath $VirtioIsoPath -PathType Leaf) -or [IO.Path]::GetExtension($VirtioIsoPath) -ine '.iso'){throw 'Select an existing VirtIO ISO.'}
    $workRoot=[IO.Path]::GetFullPath((Join-Path $Settings.ProjectRoot 'local\virtio-extract')).TrimEnd('\')
    $temporary=Join-Path $workRoot ([guid]::NewGuid().ToString('N'))
    if(-not([IO.Path]::GetFullPath($temporary).StartsWith($workRoot+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Unexpected VirtIO extraction path.'}
    New-Item -ItemType Directory -Path $temporary -Force|Out-Null
    try{
        $extracted=Expand-VirtioGuestTools -IsoPath ([IO.Path]::GetFullPath($VirtioIsoPath)) -DestinationDirectory $temporary
        Assert-ImagePackage -Path $extracted -Package $package
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force|Out-Null
        Copy-Item -LiteralPath $extracted -Destination $destination -Force
        return $destination
    }finally{
        $resolved=(Resolve-Path -LiteralPath $temporary -ErrorAction Stop).ProviderPath
        if(-not$resolved.StartsWith($workRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'VirtIO extraction cleanup escaped its workspace.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
