function script:Invoke-PveServicingTool {
    param([string]$Executable,[string[]]$Arguments,[string]$Stage)
    $output=@()
    $priorErrorAction=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $output=@(& $Executable @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode=$LASTEXITCODE
    } finally { $ErrorActionPreference=$priorErrorAction }
    $entry=[ordered]@{Stage=$Stage;Executable=$Executable;Version=(Get-Item -LiteralPath $Executable).VersionInfo.FileVersion;Arguments=$Arguments;ExitCode=$exitCode;Output=$output;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
    $filename=$Stage+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.json'
    [IO.File]::WriteAllText((Join-Path $script:PveRunLogDirectory $filename),($entry|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    foreach($line in $output){Write-Log $line}
    if($exitCode -ne 0 -and $exitCode -ne 3010){
        $message=("$Stage failed (exit $exitCode). Logs: "+$script:PveRunLogDirectory)
        if(($output -join ' ') -match 'c0000035'){$message+=' BCD hive collision: the host BCD must not be unloaded or modified; a compatible servicing environment is required.'}
        throw $message
    }
}
function script:Create-BCDBootConfig {
    param([string]$systemDrive,[string]$windowsDrive,[string]$diskLayout,$image)
    if($diskLayout -ne 'UEFI'){throw 'Only UEFI is supported by this project.'}
    $systemLetter=$systemDrive.TrimEnd(':','\')
    $windowsLetter=$windowsDrive.TrimEnd(':','\')
    $efi=Get-Partition -DriveLetter $systemLetter
    $windows=Get-Partition -DriveLetter $windowsLetter
    $targetDisk=$efi|Get-Disk
    if($efi.DiskNumber -ne $windows.DiskNumber -or $targetDisk.IsBoot -or $targetDisk.IsSystem){throw 'Refusing BCDBoot against a host system disk or mismatched partitions.'}
    if([guid]$efi.GptType -ne [guid]'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'){throw 'The selected system partition is not an EFI system partition.'}
    if($script:PveServicingIsoPath){
        $script:PveDeferredServicing=$true
        $script:PveServicingWindowsDrive=$windowsDrive.TrimEnd('\')
        $resources=$script:PveServicingWindowsDrive+'\UnattendResources'
        New-Item -ItemType Directory -Path (Join-Path $resources 'PveDrivers') -Force|Out-Null
        [IO.File]::WriteAllText((Join-Path $resources 'pve-servicing-marker.txt'),'PVE builder: service only this newly created image disk.')
        [IO.File]::WriteAllText((Join-Path $resources 'pve-efi-partition.txt'),[string]$efi.PartitionNumber,[Text.Encoding]::ASCII)
        Write-Log 'EFI boot configuration deferred to the isolated Windows PE servicing VM.'
        return
    }
    $tool=$script:PveServicingTools.BcdbootPath
    $help=(& $tool /? 2>&1|Out-String)
    $arguments=@(($windowsDrive.TrimEnd('\')+'\Windows'),'/s',$systemDrive,'/f','UEFI','/v')
    # Current Microsoft tools support offline servicing without firmware sync.
    if($help -match '/offline'){$arguments+='/offline'}
    Invoke-PveServicingTool -Executable $tool -Arguments $arguments -Stage 'bcdboot'
    if(-not(Test-Path -LiteralPath ($systemDrive.TrimEnd('\')+'\EFI\Microsoft\Boot\BCD'))){throw 'BCDBoot did not create the image EFI BCD store.'}
}
function script:Add-DriversToImage {
    param([string]$winImagePath,[string]$driversPath)
    if($script:PveDeferredServicing){
        if($winImagePath.TrimEnd('\') -ine $script:PveServicingWindowsDrive){throw 'Driver staging target differs from the build Windows partition.'}
        $destination=$winImagePath.TrimEnd('\')+'\UnattendResources\PveDrivers\'+[guid]::NewGuid().ToString('N')
        Copy-Item -LiteralPath $driversPath -Destination $destination -Recurse
        Write-Log ('Staged drivers for Windows PE servicing: '+$driversPath)
        return
    }
    $tool=$script:PveServicingTools.DismPath
    $log=Join-Path $script:PveRunLogDirectory ('dism-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.log')
    Invoke-PveServicingTool -Executable $tool -Arguments @(('/image:'+$winImagePath),'/Add-Driver',('/driver:'+$driversPath),'/recurse',('/LogPath:'+$log)) -Stage 'dism-add-driver'
}
