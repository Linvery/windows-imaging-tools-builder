function Get-ImageServicingTools {
    $adk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64'
    $result = [ordered]@{}
    foreach ($entry in @(@{Name='Dism';Relative='DISM\dism.exe';System='dism.exe'},@{Name='Bcdboot';Relative='BCDBoot\bcdboot.exe';System='bcdboot.exe'})) {
        $candidates = @((Join-Path $env:windir ('System32\'+$entry.System)),(Join-Path $adk $entry.Relative)) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        $selected = $candidates | Sort-Object { [version]([regex]::Match((Get-Item -LiteralPath $_).VersionInfo.FileVersion,'\d+\.\d+\.\d+\.\d+').Value) } -Descending | Select-Object -First 1
        if (-not $selected) { throw ('Missing servicing tool: ' + $entry.Name) }
        $result[$entry.Name+'Path'] = $selected
        $result[$entry.Name+'Version'] = (Get-Item -LiteralPath $selected).VersionInfo.FileVersion
    }
    [PSCustomObject]$result
}
function Assert-ImageBuildInputs {
    param($Settings,$Config,[switch]$CheckHost)
    . (Join-Path $ProjectRoot 'scripts\Configuration.Common.ps1')
    . (Join-Path $ProjectRoot 'scripts\Software.Selection.ps1')
    . (Join-Path $ProjectRoot 'scripts\Builder.Workflow.ps1')
    $hostInfo = $null
    if ($CheckHost) { $hostInfo = Get-BuilderHost }
    Assert-BuilderFile -Path $Config.wim_file_path -Extensions @('.iso','.wim')
    Assert-BuilderFile -Path $Config.virtio_iso_path -Extensions @('.iso')
    Assert-BuilderOutput -Path $Config.image_path
    if ($Config.virtual_disk_format -ne 'QCOW2' -or $Config.image_type -ne 'KVM' -or $Config.disk_layout -ne 'UEFI') { throw 'This project requires KVM / QCOW2 / UEFI.' }
    if (-not (Get-BuilderToolStatus -Settings $Settings)) { throw 'Prepare the pinned QEMU tool with Install-QemuImageTool.ps1.' }
    $project = Get-BuildDependencies
    $revision = (& $Settings.GitPath -C $Settings.UpstreamRoot rev-parse HEAD) -join ''
    if ($LASTEXITCODE -ne 0 -or $revision -ne $project.UpstreamCommit) { throw 'Upstream revision does not match the pinned project version.' }
    $selection = Get-GuestSoftwareSelection -ResourceRoot $Config.custom_resources_path
    if ($selection.PSObject.Properties['ProductKeyMode']) {
        $selectedKey=Resolve-PveProductKey -ImageName $Config.image_name -Mode $selection.ProductKeyMode -ProductKey ([string]$Config.product_key)
        if ($selection.ProductKeyMode -ne 'Legacy' -and $selectedKey -cne ([string]$Config.product_key).Trim().ToUpperInvariant()) { throw 'Product key config does not match its selection mode.' }
    }
    $servicingIso=$null
    $isoProperty=$selection.PSObject.Properties['ServicingIsoPath']
    if($isoProperty){$servicingIso=$isoProperty.Value}
    if(-not$servicingIso -and [IO.Path]::GetExtension($Config.wim_file_path) -ieq '.iso'){$servicingIso=$Config.wim_file_path}
    foreach ($package in @(Get-SelectedImagePackages -SkipChrome:(-not $selection.InstallChrome) -SkipVSCode:(-not $selection.InstallVSCode))) {
        Assert-ImagePackage -Path (Join-Path $Config.custom_resources_path $package.File) -Package $package
    }
    if ($CheckHost) {
        if(-not$servicingIso -or -not(Test-Path -LiteralPath $servicingIso -PathType Leaf)){throw 'Provide a matching Windows installer ISO with New-ImageConfig.ps1 -ServicingIsoPath.'}
        if ($Config.external_switch -notin @($hostInfo.Switches | ForEach-Object Name)) { throw 'Select an existing external Hyper-V switch.' }
        Assert-BuilderCapacity -CpuCount $Config.cpu_count -RamBytes $Config.ram_size -HostCpuCount $hostInfo.LogicalProcessors -HostRamBytes ([long]$hostInfo.MemoryGiB*1GB)
        Assert-BuilderDiskSpace -OutputPath $Config.image_path -DiskGiB ([int]($Config.disk_size/1GB))
        $oldWhatIf = $WhatIfPreference
        try { $WhatIfPreference=$false; $images=@(Get-BuilderSourceImages -SourcePath $Config.wim_file_path) }
        finally { $WhatIfPreference=$oldWhatIf }
        $edition=@($images | Where-Object ImageName -eq $Config.image_name)
        if ($edition.Count -ne 1) { throw 'Selected Windows edition was not found in the installation source.' }
        return [PSCustomObject]@{ImageVersion=$edition[0].ImageVersion.ToString();ImageName=$edition[0].ImageName;Software=$selection;HostChecks='passed'}
    }
    return [PSCustomObject]@{Software=$selection;HostChecks='not_checked'}
}
function Get-OfflineBuildVerification {
    param([string]$VhdPath,[string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $mountedHere=$false
    try {
        if ((Get-VHD -Path $VhdPath).Attached) { throw 'Verification requires an offline build disk.' }
        Mount-VHD -Path $VhdPath -ReadOnly | Out-Null
        $mountedHere=$true
        $volumes=@(Get-VHD -Path $VhdPath | Get-Disk | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path -LiteralPath ($_.DriveLetter+':\Windows\System32\config\SOFTWARE')) })
        if ($volumes.Count -ne 1) { throw 'Could not locate exactly one Windows partition for verification.' }
        $drive=$volumes[0].DriveLetter+':\'
        $proof=Join-Path $drive 'ProgramData\PveImageBuilder\build-verification.json'
        if (-not(Test-Path -LiteralPath $proof)){throw 'The guest did not produce its required installation verification.'}
        $verification=Get-Content -Raw -Encoding UTF8 -LiteralPath $proof | ConvertFrom-Json
        Copy-Item -LiteralPath $proof -Destination (Join-Path $Directory 'guest-verification.json')
        $verification | Add-Member -NotePropertyName ActivationReportPresentAtBuild -NotePropertyValue (Test-Path -LiteralPath (Join-Path $drive 'ProgramData\PveImageBuilder\windows-activation.json'))
        $verification | Add-Member -NotePropertyName WindowsActivationScriptStaged -NotePropertyValue (Test-Path -LiteralPath (Join-Path $drive 'Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\30-WindowsActivation.ps1'))
        $setupLog=Join-Path $drive 'Windows\System32\Sysprep\Panther\setupact.log'
        if(Test-Path -LiteralPath $setupLog){Copy-Item -LiteralPath $setupLog -Destination (Join-Path $Directory 'sysprep-setupact.log')}
        # Parse the copied hive as data; never mount or change host HKLM keys.
        $hivePath=Join-Path $Directory 'SOFTWARE'
        Copy-Item -LiteralPath (Join-Path $drive 'Windows\System32\config\SOFTWARE') -Destination $hivePath
        foreach($suffix in @('.LOG1','.LOG2')){
            $transaction=Join-Path $drive ('Windows\System32\config\SOFTWARE'+$suffix)
            if(Test-Path -LiteralPath $transaction){Copy-Item -LiteralPath $transaction -Destination ($hivePath+$suffix)}
        }
        . (Join-Path $PSScriptRoot 'Offline.Registry.ps1')
        $imageState=Get-OfflineImageState -HivePath $hivePath
        if($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'){throw ('Sysprep did not generalize the image: '+$imageState)}
        if(-not$verification.QemuGuestAgent -or -not$verification.CloudbaseInit){throw 'Guest verification is missing required services.'}
        $verification|Add-Member -NotePropertyName SysprepImageState -NotePropertyValue $imageState -PassThru
    } finally {
        if($mountedHere){Dismount-VHD -Path $VhdPath}
    }
}
