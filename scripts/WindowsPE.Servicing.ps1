function Invoke-WindowsPeServicing {
    param([string]$VhdPath,[string]$WindowsIsoPath,[string]$LogDirectory)
    $ErrorActionPreference='Stop'
    . (Join-Path $PSScriptRoot 'Build.Resources.ps1')
    if((Get-VHD -Path $VhdPath).Attached){throw 'Windows PE servicing requires a detached build VHDX.'}
    if(-not(Test-Path -LiteralPath $WindowsIsoPath -PathType Leaf)){throw 'A Windows installer ISO is required for Windows PE servicing.'}
    $mediaRoot=Join-Path $LogDirectory 'media'
    Register-PveBuildDirectory -ContextPath $script:PveResourceContextPath -Path $mediaRoot
    $scripts=Join-Path $mediaRoot 'PveServicing'
    New-Item -ItemType Directory -Path $scripts -Force|Out-Null
    $batch=@'
@echo off
setlocal
wpeinit
set "OS="
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%L:\UnattendResources\pve-servicing-marker.txt set "OS=%%L:"
if not defined OS goto no_os
ver > "%OS%\UnattendResources\winpe-version.txt"
set /p EFI_PARTITION=< "%OS%\UnattendResources\pve-efi-partition.txt"
if not defined EFI_PARTITION goto failed
> X:\pve-assign-efi.txt echo select disk 0
>> X:\pve-assign-efi.txt echo select partition %EFI_PARTITION%
>> X:\pve-assign-efi.txt echo assign letter=S
>> X:\pve-assign-efi.txt echo exit
diskpart /s X:\pve-assign-efi.txt > "%OS%\UnattendResources\winpe-diskpart.log" 2>&1
if errorlevel 1 goto failed
if not exist S:\ goto failed
dism.exe /Image:%OS%\ /Add-Driver /Driver:%OS%\UnattendResources\PveDrivers /Recurse /LogPath:%OS%\UnattendResources\winpe-dism.log > "%OS%\UnattendResources\winpe-dism-output.txt" 2>&1
set "DISMEXIT=%ERRORLEVEL%"
if not "%DISMEXIT%"=="0" if not "%DISMEXIT%"=="3010" goto failed
bcdboot.exe "%OS%\Windows" /s S: /f UEFI /v > "%OS%\UnattendResources\winpe-bcdboot-output.txt" 2>&1
if errorlevel 1 goto failed
if not exist S:\EFI\Microsoft\Boot\BCD goto failed
echo {"Phase":"complete","Disk":0,"BootMode":"UEFI"} > "%OS%\UnattendResources\winpe-servicing-status.json"
wpeutil shutdown
exit /b 0
:failed
echo {"Phase":"failed","Disk":0,"BootMode":"UEFI"} > "%OS%\UnattendResources\winpe-servicing-status.json"
wpeutil shutdown
exit /b 1
:no_os
wpeutil shutdown
exit /b 2
'@
    [IO.File]::WriteAllText((Join-Path $scripts 'run.cmd'),($batch -replace '\r?\n',"`r`n"),[Text.Encoding]::ASCII)
    $answer=@'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>__UI_LANGUAGE__</UILanguage></SetupUILanguage>
      <InputLocale>__UI_LANGUAGE__</InputLocale><SystemLocale>__UI_LANGUAGE__</SystemLocale><UILanguage>__UI_LANGUAGE__</UILanguage><UserLocale>__UI_LANGUAGE__</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd.exe /c for %d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do @if exist %d:\PveServicing\run.cmd call %d:\PveServicing\run.cmd</Path>
          <Description>Service only the attached PVE image disk</Description>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
'@
    $mountedIsoHere=$false
    try {
        $sourceDisk=Get-DiskImage -ImagePath $WindowsIsoPath
        if(-not$sourceDisk.Attached){Mount-DiskImage -ImagePath $WindowsIsoPath -StorageType ISO|Out-Null;$mountedIsoHere=$true}
        $sourceVolumes=@(Get-DiskImage -ImagePath $WindowsIsoPath|Get-Volume|Where-Object DriveLetter)
        if($sourceVolumes.Count -ne 1){throw 'Could not identify the Windows installer ISO volume.'}
        $sourceRoot=$sourceVolumes[0].DriveLetter+':\'
        foreach($name in @('boot','efi')){Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $mediaRoot $name) -Recurse}
        New-Item -ItemType Directory -Path (Join-Path $mediaRoot 'sources') -Force|Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'sources\boot.wim') -Destination (Join-Path $mediaRoot 'sources\boot.wim')
        foreach($name in @('bootmgr','bootmgr.efi','setup.exe')){if(Test-Path -LiteralPath (Join-Path $sourceRoot $name)){Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $mediaRoot $name)}}
        $uiLanguage='en-US'
        $langPath=Join-Path $sourceRoot 'sources\lang.ini'
        if(Test-Path -LiteralPath $langPath){$match=[regex]::Match([IO.File]::ReadAllText($langPath),'(?im)^([a-z]{2,3}-[a-z0-9]{2,8})\s*=');if($match.Success){$uiLanguage=$match.Groups[1].Value}}
        $answer=$answer.Replace('__UI_LANGUAGE__',$uiLanguage)
    } finally {if($mountedIsoHere){Dismount-DiskImage -ImagePath $WindowsIsoPath|Out-Null}}
    [IO.File]::WriteAllText((Join-Path $mediaRoot 'Autounattend.xml'),$answer,[Text.UTF8Encoding]::new($false))
    $oscdimg=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    if(-not(Test-Path -LiteralPath $oscdimg)){throw 'Microsoft ADK Deployment Tools (oscdimg) is required for Windows PE servicing.'}
    $mediaIso=Join-Path $LogDirectory 'servicing.iso'
    Register-PveBuildFile -ContextPath $script:PveResourceContextPath -Path $mediaIso
    $efiBoot=Join-Path $mediaRoot 'efi\microsoft\boot\efisys_noprompt.bin'
    if(-not(Test-Path -LiteralPath $efiBoot)){$efiBoot=Join-Path (Split-Path -Parent $oscdimg) 'efisys_noprompt.bin'}
    if(-not(Test-Path -LiteralPath $efiBoot)){throw 'Microsoft efisys_noprompt.bin is required for unattended Windows PE boot.'}
    $priorErrorAction=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$output=@(& $oscdimg -m -o -u2 -udfver102 ('-bootdata:1#pEF,e,b'+$efiBoot) '-lPVE-SERVICE' $mediaRoot $mediaIso 2>&1|ForEach-Object{$_.ToString()});$exitCode=$LASTEXITCODE}
    finally{$ErrorActionPreference=$priorErrorAction}
    [IO.File]::WriteAllText((Join-Path $LogDirectory 'oscdimg.txt'),($output -join [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    if($exitCode -ne 0){throw 'Could not create the Windows PE servicing answer ISO.'}
    $vmName='PveBuilder-WinPE-'+[guid]::NewGuid().ToString('N').Substring(0,12)
    $vm=$null;$mountedHere=$false;$successful=$false
    $state=[ordered]@{Phase='starting';VMName=$vmName;VhdPath=$VhdPath;WindowsIsoPath=$WindowsIsoPath;StartedUtc=[DateTime]::UtcNow.ToString('o')}
    function Save-WinPeState{[IO.File]::WriteAllText((Join-Path $LogDirectory 'status.json'),($state|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))}
    try{
        Save-WinPeState
        # Exactly one hard disk, with no network or shared host drives.
        Register-PveBuildVm -ContextPath $script:PveResourceContextPath -Name $vmName -VhdPath $VhdPath
        $vm=New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 4GB -VHDPath $VhdPath
        Register-PveBuildVm -ContextPath $script:PveResourceContextPath -Name $vmName -VhdPath $VhdPath -Id ([string]$vm.Id)
        Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
        Set-VMProcessor -VM $vm -Count 2
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
        $installerDvd=Add-VMDvdDrive -VM $vm -Path $mediaIso -Passthru
        Add-VMDvdDrive -VM $vm -Path $WindowsIsoPath|Out-Null
        Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice $installerDvd
        Start-VM -VM $vm
        $state.Phase='servicing';Save-WinPeState
        $deadline=[DateTime]::UtcNow.AddMinutes(20)
        Start-Sleep -Seconds 10
        while((Get-VM -Id $vm.Id).State -ne 'Off'){
            if([DateTime]::UtcNow -gt $deadline){throw ('Windows PE servicing timed out; inspect '+$vmName)}
            Start-Sleep -Seconds 3
        }
        Mount-VHD -Path $VhdPath -ReadOnly|Out-Null;$mountedHere=$true
        $windowsVolumes=@(Get-VHD -Path $VhdPath|Get-Disk|Get-Partition|Get-Volume|Where-Object{ $_.DriveLetter -and (Test-Path -LiteralPath ($_.DriveLetter+':\UnattendResources\pve-servicing-marker.txt')) })
        if($windowsVolumes.Count -ne 1){throw 'Could not find the serviced Windows partition.'}
        $resources=$windowsVolumes[0].DriveLetter+':\UnattendResources'
        foreach($name in @('winpe-servicing-status.json','winpe-version.txt','winpe-diskpart.log','winpe-dism.log','winpe-dism-output.txt','winpe-bcdboot-output.txt')){
            $path=Join-Path $resources $name
            if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination (Join-Path $LogDirectory $name)}
        }
        $resultPath=Join-Path $LogDirectory 'winpe-servicing-status.json'
        if(-not(Test-Path -LiteralPath $resultPath)){throw 'Windows Setup did not execute the Windows PE servicing answer file.'}
        $result=Get-Content -Raw -Encoding UTF8 -LiteralPath $resultPath|ConvertFrom-Json
        if($result.Phase -ne 'complete'){throw ('Isolated Windows PE servicing failed; inspect '+$LogDirectory)}
        $state.Phase='complete';$state.CompletedUtc=[DateTime]::UtcNow.ToString('o');Save-WinPeState
        $successful=$true
    }catch{$state.Phase='failed';$state.Error=$_.Exception.Message;Save-WinPeState;throw}
    finally{
        if($mountedHere){Dismount-VHD -Path $VhdPath}
        if($vm){$own=Get-VM -Id $vm.Id -ErrorAction SilentlyContinue;if($own){if($own.State -ne 'Off'){Stop-VM -VM $own -TurnOff -Force};if($successful){Remove-VM -VM $own -Force}}}
    }
}
