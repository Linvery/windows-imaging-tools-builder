param([Parameter(Mandatory=$true)]$Settings,[string]$ResourceContextPath)
Import-Module (Join-Path $Settings.UpstreamRoot 'WinImageBuilder.psm1') -Force
Import-Module (Join-Path $Settings.UpstreamRoot 'Config.psm1') -Force
& (Get-Module WinImageBuilder) {
    param($ProjectRoot,$AssetsRoot,$ManifestPath,$ResourceContextPath)
    $script:PveProjectRoot=$ProjectRoot;$script:PveAssetsRoot=$AssetsRoot;$script:PveQemuManifest=$ManifestPath
    $script:PveDeferredServicing=$false
    $script:PveServicingIsoPath=$null
    $script:PveResourceContextPath=$ResourceContextPath
    $script:PveProductKeyMode='Legacy'
    . (Join-Path $ProjectRoot 'scripts\Build.Resources.ps1')
    . (Join-Path $ProjectRoot 'scripts\CloudbaseInit.Resources.ps1')
    if (-not (Get-Variable -Name PveOriginalDownloadCloudbaseInit -Scope Script -ErrorAction SilentlyContinue)) { $script:PveOriginalDownloadCloudbaseInit=${function:Download-CloudbaseInit} }
    function script:Download-CloudbaseInit {
        param([string]$resourcesDir,[string]$osArch,[switch]$BetaRelease,[string]$MsiPath,[string]$CloudbaseInitConfigPath,[string]$CloudbaseInitUnattendedConfigPath)
        $cachePath=Get-PveCloudbaseInitCachePath -AssetsRoot $script:PveAssetsRoot -OsArch $osArch -BetaRelease:$BetaRelease
        $templatePath=Get-PveCloudbaseInitCachePath -AssetsRoot $script:PveAssetsRoot
        if (-not $MsiPath -or [IO.Path]::GetFullPath($MsiPath) -in @($cachePath,$templatePath)) {
            $PSBoundParameters['MsiPath']=Execute-Retry {
                Initialize-PveCloudbaseInitInstaller -AssetsRoot $script:PveAssetsRoot -OsArch $osArch -BetaRelease:$BetaRelease
            }
        }
        & $script:PveOriginalDownloadCloudbaseInit @PSBoundParameters
    }
    . (Join-Path $ProjectRoot 'scripts\Unattend.Adapter.ps1')
    if (-not (Get-Variable -Name PveOriginalGenerateUnattend -Scope Script -ErrorAction SilentlyContinue)) { $script:PveOriginalGenerateUnattend=${function:Generate-UnattendXml} }
    function script:Generate-UnattendXml {
        param([string]$inUnattendXmlPath,[string]$outUnattendXmlPath,$image,[string]$productKey,$administratorPassword)
        $setupKey=Get-PveSetupProductKey -Image $image -RequestedProductKey $productKey -Mode $script:PveProductKeyMode
        $automatic=($script:PveProductKeyMode -eq 'Kms' -or (-not $productKey -and -not [string]::IsNullOrWhiteSpace($setupKey)))
        if ($setupKey) { $PSBoundParameters['productKey']=$setupKey }
        else { $PSBoundParameters.Remove('productKey') | Out-Null }
        & $script:PveOriginalGenerateUnattend @PSBoundParameters
        Update-PveUnattendSettings -Path $outUnattendXmlPath -Image $image -AutomaticSetupKey:$automatic
        if ($automatic) { Write-Log 'Public KMS client setup key supplied for the selected edition; build-time automatic activation disabled.' }
    }
    . (Join-Path $ProjectRoot 'scripts\Servicing.Adapter.ps1')
    if (-not (Get-Variable -Name PveOriginalGetPath -Scope Script -ErrorAction SilentlyContinue)) { $script:PveOriginalGetPath = ${function:Get-PathWithoutExtension} }
    function script:Get-PathWithoutExtension {
        param([string]$Path,[int]$Depth=0)
        if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -in @('.qcow2','.vhdx','.vhd','.raw')) {
            return Join-Path ([IO.Path]::GetDirectoryName($Path)) ([IO.Path]::GetFileNameWithoutExtension($Path))
        }
        & $script:PveOriginalGetPath -Path $Path -Depth $Depth
    }
    if (-not (Get-Variable -Name PveOriginalRunSysprep -Scope Script -ErrorAction SilentlyContinue)) {
        $script:PveOriginalRunSysprep = ${function:Run-Sysprep}
    }
    if (-not (Get-Variable -Name PveOriginalCopyUnattendResources -Scope Script -ErrorAction SilentlyContinue)) { $script:PveOriginalCopyUnattendResources=${function:Copy-UnattendResources} }
    function script:Copy-UnattendResources {
        param([string]$resourcesDir,[string]$imageInstallationType,[bool]$InstallMaaSHooks,[string]$VMwareToolsPath)
        & $script:PveOriginalCopyUnattendResources @PSBoundParameters
        Copy-Item -LiteralPath (Join-Path $script:PveProjectRoot 'resources\Builder.Specialize.ps1') -Destination (Join-Path $resourcesDir 'Specialize.ps1') -Force
    }
    if (-not (Get-Variable -Name PveOriginalAddVirtioIso -Scope Script -ErrorAction SilentlyContinue)) { $script:PveOriginalAddVirtioIso=${function:Add-VirtIODriversFromISO} }
    function script:Add-VirtIODriversFromISO {
        param([string]$vhdDriveLetter,$image,[string]$isoPath)
        if ($script:PveResourceContextPath) {
            $directory=Join-Path $script:PveRunLogDirectory ('temporary-virtio-'+[guid]::NewGuid().ToString('N'))
            Register-PveBuildDirectory -ContextPath $script:PveResourceContextPath -Path $directory
            New-Item -ItemType Directory -Path $directory | Out-Null
            $copy=Join-Path $directory 'virtio.iso'
            Copy-Item -LiteralPath $isoPath -Destination $copy
            try { & $script:PveOriginalAddVirtioIso -vhdDriveLetter $vhdDriveLetter -image $image -isoPath $copy }
            finally {
                if (Test-Path -LiteralPath $copy -PathType Leaf) { Assert-PveResourcePath -Path $copy -Root $directory -Descendant | Out-Null; Remove-Item -LiteralPath $copy -Force }
                if ((Test-Path -LiteralPath $directory -PathType Container) -and -not @(Get-ChildItem -LiteralPath $directory -Force).Count) { Remove-Item -LiteralPath $directory }
            }
        } else { & $script:PveOriginalAddVirtioIso @PSBoundParameters }
    }
    function script:Run-Sysprep {
        param([string]$Name,[string]$VhdPath,[uint64]$Memory,[int]$CpuCores,[string]$VMSwitch,[string]$Generation='1',[switch]$DisableSecureBoot)
        if($script:PveDeferredServicing){
            . (Join-Path $script:PveProjectRoot 'scripts\WindowsPE.Servicing.ps1')
            Write-Log 'Starting isolated Windows PE EFI configuration and driver injection.'
            Invoke-WindowsPeServicing -VhdPath $VhdPath -WindowsIsoPath $script:PveServicingIsoPath -LogDirectory (Join-Path $script:PveRunLogDirectory 'windows-pe')
        }
        if ($script:PveResourceContextPath) {
            $Name='PveBuilder-Sysprep-'+[guid]::NewGuid().ToString('N')
            $PSBoundParameters['Name']=$Name
            Register-PveBuildVm -ContextPath $script:PveResourceContextPath -Name $Name -VhdPath $VhdPath
        }
        try { & $script:PveOriginalRunSysprep @PSBoundParameters }
        catch {
            $own=Get-VM -Name $Name -ErrorAction SilentlyContinue
            if($own){$disks=@(Get-VMHardDiskDrive -VM $own);if($disks.Count -eq 1 -and $disks[0].Path -ieq $VhdPath -and $own.State -ne 'Off'){Stop-VM -VM $own -TurnOff -Force}}
            throw
        }
        . (Join-Path $script:PveProjectRoot 'scripts\Build.Validation.ps1')
        $verification=Get-OfflineBuildVerification -VhdPath $VhdPath -Directory (Join-Path $script:PveRunLogDirectory 'verification')
        [IO.File]::WriteAllText((Join-Path $script:PveRunLogDirectory 'verified-guest.json'),($verification|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
        Write-Log 'Guest software, required services, and generalized Sysprep state verified.'
    }
    function script:Wait-ForVMShutdown {
        param([string]$Name)
        $deadline=[DateTime]::UtcNow.AddHours(4)
        $lastMessages=@{}
        if ($script:PveResourceContextPath) {
            $owned=Get-VM -Name $Name -ErrorAction Stop
            $ownedDisks=@(Get-VMHardDiskDrive -VM $owned -ErrorAction Stop)
            if ($ownedDisks.Count -ne 1) { throw 'The build VM must have exactly one owned disk.' }
            Register-PveBuildVm -ContextPath $script:PveResourceContextPath -Name $Name -VhdPath $ownedDisks[0].Path -Id ([string]$owned.Id)
        }
        while ((Get-VM -Name $Name).State -ne 'Off') {
            if([DateTime]::UtcNow -gt $deadline){throw ('Build VM timed out; retained for diagnosis: '+$Name)}
            $messages=$null
            try { $messages=Get-KVPData -VMName $Name } catch { Write-Verbose 'VM runtime logs are not available yet.' }
            if($messages){foreach($key in $messages.Keys){if($lastMessages[$key] -ne $messages[$key]){Write-Log ('{0}: {1}' -f $key,$messages[$key])};if($key -ieq 'ERROR'){throw ('Build guest reported an error; VM retained for diagnosis: '+$Name+'. '+$messages[$key])}};$lastMessages=$messages}
            Start-Sleep -Seconds 3
        }
    }
    function script:Convert-VirtualDisk {
        param([Parameter(Mandatory=$true)][string]$vhdPath,[Parameter(Mandatory=$true)][string]$outPath,[Parameter(Mandatory=$true)][string]$format,[bool]$CompressQcow2)
        if($format.ToLower() -eq 'qcow2' -and $CompressQcow2){
            $result=& (Join-Path $script:PveProjectRoot 'src\Compress-Qcow2Image.ps1') -SourcePath $vhdPath -OutputPath $outPath -ToolManifestPath $script:PveQemuManifest -BackupDirectory (Join-Path $script:PveAssetsRoot 'archive\verified-builds') -ReplaceExisting -ResourceContextPath $script:PveResourceContextPath
            Write-Log ('Verified compressed image: '+$result.OutputPath)
        }else{
            $manifest=Get-Content -Raw -Encoding UTF8 -LiteralPath $script:PveQemuManifest|ConvertFrom-Json
            & $manifest.ExecutablePath convert -m 1 -O $format $vhdPath $outPath
            if($LASTEXITCODE -ne 0){throw 'Disk conversion failed.'}
        }
    }
} $Settings.ProjectRoot $Settings.AssetsRoot $Settings.QemuManifestPath $ResourceContextPath
