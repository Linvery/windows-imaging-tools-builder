function script:Save-PveBuildResources {
    param([string]$ContextPath,$Context)
    $temporary=$ContextPath+'.writing-'+[guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary,($Context|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $ContextPath) { [IO.File]::Replace($temporary,$ContextPath,[NullString]::Value) }
    else { [IO.File]::Move($temporary,$ContextPath) }
}
function script:Get-PveBuildResources {
    param([string]$ContextPath)
    $context=Get-Content -Raw -Encoding UTF8 -LiteralPath $ContextPath | ConvertFrom-Json
    if ($context.SchemaVersion -ne 1 -or -not $context.RunId) { throw 'Invalid build resource context.' }
    return $context
}
function script:Assert-PveResourcePath {
    param([string]$Path,[string]$Root,[switch]$Descendant)
    $full=[IO.Path]::GetFullPath($Path)
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($Descendant) {
        if (-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Resource path escaped its run directory.' }
    } elseif ($full -ine $base) { throw 'Resource path does not match its recorded owner.' }
    return $full
}
function script:Test-PveBuildFilePath {
    param($Context,[string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if ($full -in @($Context.OutputPath,[IO.Path]::ChangeExtension($Context.OutputPath,'.vhdx'),[IO.Path]::ChangeExtension($Context.OutputPath,'.raw'))) { return $true }
    if ($full -in @((Join-Path $Context.LogDirectory 'build.ini'),(Join-Path $Context.LogDirectory 'build.ini.offline'),(Join-Path $Context.LogDirectory 'windows-pe\servicing.iso'))) { return $true }
    $prefix=[IO.Path]::GetFileNameWithoutExtension($Context.OutputPath)+'.compressing-'
    return ([IO.Path]::GetDirectoryName($full) -ieq [IO.Path]::GetDirectoryName($Context.OutputPath) -and [IO.Path]::GetFileName($full).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetExtension($full) -ieq '.qcow2')
}
function script:Register-PveBuildFile {
    param([string]$ContextPath,[string]$Path,[ValidateSet('Disk','Temporary')][string]$Kind='Temporary')
    if (-not $ContextPath) { return }
    $context=Get-PveBuildResources -ContextPath $ContextPath
    $full=[IO.Path]::GetFullPath($Path)
    if (@($context.Files|Where-Object Path -ieq $full).Count) { return }
    $allowed=Test-PveBuildFilePath -Context $context -Path $full
    if (-not $allowed) { throw 'Unrecognized temporary build file.' }
    if (Test-Path -LiteralPath $full) { throw ('Resource already exists; do not adopt it: '+$full) }
    $context.Files=@($context.Files)+[PSCustomObject]@{Path=$full;Kind=$Kind;ExistedBefore=$false}
    Save-PveBuildResources -ContextPath $ContextPath -Context $context
}
function script:Register-PveBuildDirectory {
    param([string]$ContextPath,[string]$Path)
    if (-not $ContextPath) { return }
    $context=Get-PveBuildResources -ContextPath $ContextPath
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (@($context.Directories|Where-Object Path -ieq $full).Count) { return }
    $work=[IO.Path]::GetFullPath((Join-Path $context.AssetsRoot 'work')).TrimEnd('\')+'\'
    $logs=[IO.Path]::GetFullPath($context.LogDirectory).TrimEnd('\')+'\'
    if (-not $full.StartsWith($work,[StringComparison]::OrdinalIgnoreCase) -and -not $full.StartsWith($logs,[StringComparison]::OrdinalIgnoreCase)) { throw 'Temporary directory escaped its build roots.' }
    if (Test-Path -LiteralPath $full) { throw ('Resource already exists; do not adopt it: '+$full) }
    $context.Directories=@($context.Directories)+[PSCustomObject]@{Path=$full;ExistedBefore=$false}
    Save-PveBuildResources -ContextPath $ContextPath -Context $context
}
function script:Register-PveBuildVm {
    param([string]$ContextPath,[string]$Name,[string]$VhdPath,[string]$Id)
    if (-not $ContextPath) { return }
    $context=Get-PveBuildResources -ContextPath $ContextPath
    $disk=[IO.Path]::GetFullPath($VhdPath)
    $ownedDisk=@($context.Files|Where-Object { $_.Kind -eq 'Disk' -and $_.Path -ieq $disk }).Count -gt 0
    foreach ($directory in $context.Directories) { if ($disk.StartsWith($directory.Path.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { $ownedDisk=$true } }
    if (-not $ownedDisk) { throw 'Cannot register a VM attached to an unowned disk.' }
    $entry=@($context.VMs|Where-Object Name -eq $Name)
    if (-not $entry.Count) {
        if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw 'Cannot adopt an existing VM.' }
        $context.VMs=@($context.VMs)+[PSCustomObject]@{Name=$Name;Id=$Id;VhdPath=$disk;ExistedBefore=$false}
    } else { if ($Id) { $entry[0].Id=$Id } }
    Save-PveBuildResources -ContextPath $ContextPath -Context $context
}
function script:Get-PveOwnedVm {
    param($Entry)
    if ($Entry.ExistedBefore) { throw 'Refusing to modify an existing VM.' }
    $vm=$null
    if ($Entry.Id) { $vm=Get-VM -Id ([guid]$Entry.Id) -ErrorAction SilentlyContinue }
    else { $vm=Get-VM -Name $Entry.Name -ErrorAction SilentlyContinue }
    if (-not $vm) { return }
    if ($vm.Name -ne $Entry.Name) { throw 'Recorded VM identity has changed.' }
    $disks=@(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)
    if ($disks.Count -ne 1 -or [IO.Path]::GetFullPath($disks[0].Path) -ine $Entry.VhdPath) { throw 'Recorded VM no longer has exactly its owned disk.' }
    return $vm
}
function script:Stop-PveOwnedBuildVms {
    param([string]$ContextPath,[switch]$Remove)
    $context=Get-PveBuildResources -ContextPath $ContextPath
    foreach ($entry in $context.VMs) {
        $vm=Get-PveOwnedVm -Entry $entry
        if ($vm) {
            if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop }
            if ($Remove) { Remove-VM -VM $vm -Force -ErrorAction Stop }
        }
    }
}
function script:Dismount-PveOwnedDisk {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $disk=Get-VHD -Path $Path -ErrorAction Stop
    if ($disk.Attached) {
        $physical=@($disk | Get-Disk -ErrorAction Stop)
        if ($physical.Count -ne 1 -or $physical[0].IsBoot -or $physical[0].IsSystem) { throw 'Refusing to detach a host system disk.' }
        Dismount-VHD -Path $Path -ErrorAction Stop
    }
}
function script:Remove-PveOwnedBuildResources {
    param([string]$ContextPath)
    $context=Get-PveBuildResources -ContextPath $ContextPath
    if ($context.Completed) { throw 'A completed build must not be cleaned as cancelled.' }
    if ([IO.Path]::GetFullPath((Split-Path -Parent $ContextPath)) -ine [IO.Path]::GetFullPath($context.LogDirectory)) { throw 'Resource context does not belong to its recorded log directory.' }
    # Validate every deletion boundary before changing any VM or file.
    foreach ($file in $context.Files) {
        if ($file.ExistedBefore -or -not (Test-PveBuildFilePath -Context $context -Path $file.Path)) { throw 'Cleanup file is not an owned new build file.' }
    }
    foreach ($directory in $context.Directories) {
        $full=[IO.Path]::GetFullPath($directory.Path).TrimEnd('\')
        $work=[IO.Path]::GetFullPath((Join-Path $context.AssetsRoot 'work')).TrimEnd('\')+'\'
        $logs=[IO.Path]::GetFullPath($context.LogDirectory).TrimEnd('\')+'\'
        if ($directory.ExistedBefore -or (-not $full.StartsWith($work,[StringComparison]::OrdinalIgnoreCase) -and -not $full.StartsWith($logs,[StringComparison]::OrdinalIgnoreCase))) { throw 'Cleanup directory is not an owned run directory.' }
    }
    # Stop/delete identified VMs first, so their disks cannot still be written.
    Stop-PveOwnedBuildVms -ContextPath $ContextPath -Remove
    foreach ($iso in $context.SourceIsos) {
        if (-not $iso.AttachedBefore) {
            $image=Get-DiskImage -ImagePath $iso.Path -ErrorAction Stop
            if ($image.Attached) { Dismount-DiskImage -ImagePath $iso.Path -ErrorAction Stop | Out-Null }
        }
    }
    foreach ($directory in $context.Directories) {
        if ($directory.ExistedBefore) { throw 'Refusing to remove an existing directory.' }
        $full=[IO.Path]::GetFullPath($directory.Path).TrimEnd('\')
        $work=[IO.Path]::GetFullPath((Join-Path $context.AssetsRoot 'work')).TrimEnd('\')+'\'
        $logs=[IO.Path]::GetFullPath($context.LogDirectory).TrimEnd('\')+'\'
        if (-not $full.StartsWith($work,[StringComparison]::OrdinalIgnoreCase) -and -not $full.StartsWith($logs,[StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup directory escaped its build roots.' }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        $item=Get-Item -LiteralPath $full -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing to clean a linked directory.' }
        $children=@(Get-ChildItem -LiteralPath $full -Recurse -Force)
        if (@($children|Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Refusing to clean a directory containing links.' }
        foreach ($file in @($children|Where-Object { -not $_.PSIsContainer })) {
            if ($file.Extension -ieq '.vhdx') { Dismount-PveOwnedDisk -Path $file.FullName }
            elseif ($file.Extension -ieq '.iso') {
                $image=Get-DiskImage -ImagePath $file.FullName -ErrorAction Stop
                if ($image.Attached) { Dismount-DiskImage -ImagePath $file.FullName -ErrorAction Stop | Out-Null }
            }
        }
        $resolved=(Resolve-Path -LiteralPath $full).ProviderPath
        Assert-PveResourcePath -Path $resolved -Root $full | Out-Null
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    }
    foreach ($file in $context.Files) {
        if ($file.ExistedBefore) { throw 'Refusing to remove an existing file.' }
        $path=[IO.Path]::GetFullPath($file.Path)
        $allowed=Test-PveBuildFilePath -Context $context -Path $path
        if (-not $allowed) { throw 'Cleanup file escaped its output paths.' }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing to remove a linked file.' }
            if ($file.Kind -eq 'Disk') { Dismount-PveOwnedDisk -Path $path }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
    $context.Cleanup='complete'
    Save-PveBuildResources -ContextPath $ContextPath -Context $context
}
