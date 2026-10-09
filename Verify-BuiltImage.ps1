[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourcePath,[string]$ConfigPath,[string]$LogDirectory,[string]$ResourceContextPath,[switch]$Offline)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'scripts\Project.Common.ps1')
. (Join-Path $PSScriptRoot 'scripts\Software.Selection.ps1')
. (Join-Path $PSScriptRoot 'scripts\Build.Resources.ps1')
Assert-PowerShell51
Assert-Administrator
$settings=Get-ProjectSettings
if(-not$ConfigPath){$ConfigPath=Join-Path $ProjectRoot 'local\image.ini'}
Import-Module (Join-Path $settings.UpstreamRoot 'Config.psm1') -Force
$config=Get-WindowsImageConfig -ConfigFilePath $ConfigPath
$source=[IO.Path]::GetFullPath($SourcePath)
if([IO.Path]::GetFullPath($config.image_path) -ine $source){throw 'The verification config must describe this exact output image.'}
if([IO.Path]::GetExtension($source) -ine '.qcow2' -or -not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'Select an existing QCOW2 image.'}
$software=Get-GuestSoftwareSelection -ResourceRoot $config.custom_resources_path
$verifyActivation=([bool]$software.KmsServer -and (Test-Path -LiteralPath (Join-Path $config.custom_resources_path 'Activate-Windows.ps1') -PathType Leaf))
$kmsEndpoint=ConvertTo-PveKmsEndpoint -Address ([string]$software.KmsServer)
$manifest=Get-Content -Raw -Encoding UTF8 -LiteralPath $settings.QemuManifestPath | ConvertFrom-Json
$qemu=$manifest.ExecutablePath
if(-not$manifest.PublishedHashVerified -or (Get-FileHash -Algorithm SHA256 -LiteralPath $qemu).Hash -ne $manifest.ExecutableSha256){throw 'QEMU verification failed.'}
$runId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$work=Join-Path $settings.AssetsRoot ('work\boot-check-'+$runId)
if(-not$LogDirectory){$LogDirectory=Join-Path $settings.AssetsRoot ('logs\boot-check-'+$runId)}
Register-PveBuildDirectory -ContextPath $ResourceContextPath -Path $work
New-Item -ItemType Directory -Path $work,$LogDirectory -Force|Out-Null
$bootDisk=Join-Path $work 'boot-copy.vhdx'
$vmName='PveBuilder-BootCheck-'+$runId
$ownedVmId=$null
$complete=$false
$state=[ordered]@{Phase='preparing';SourcePath=$source;VmName=$vmName;BootDisk=$bootDisk;StartedUtc=[DateTime]::UtcNow.ToString('o');LogDirectory=$LogDirectory;Offline=[bool]$Offline;VerifyOptionalActivation=$verifyActivation}
function Save-BootState { [IO.File]::WriteAllText((Join-Path $LogDirectory 'status.json'),($state|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false)) }
function Invoke-BootQemu {
    param([string[]]$Arguments,[string]$Name)
    Invoke-BootNative -Executable $qemu -Arguments $Arguments -Name $Name
}
function Invoke-BootNative {
    param([string]$Executable,[string[]]$Arguments,[string]$Name)
    $priorErrorAction=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$result=@(& $Executable @Arguments 2>&1|ForEach-Object{$_.ToString()});$exitCode=$LASTEXITCODE}
    finally{$ErrorActionPreference=$priorErrorAction}
    [IO.File]::WriteAllText((Join-Path $LogDirectory ($Name+'.txt')),($result -join [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    if($exitCode -ne 0){throw ("$Name failed with exit $exitCode")}
}
try{
    Save-BootState
    $state.SourceSHA256=(Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
    Invoke-BootQemu -Arguments @('check','-f','qcow2',$source) -Name 'source-check'
    $state.Phase='converting_boot_copy';Save-BootState
    Invoke-BootQemu -Arguments @('convert','-m','1','-f','qcow2','-O','vhdx','-o','subformat=dynamic',$source,$bootDisk) -Name 'convert-boot-copy'
    if((Get-Item -LiteralPath $bootDisk).Attributes -band [IO.FileAttributes]::SparseFile){
        & fsutil.exe sparse setflag $bootDisk 0|Out-Null
        if($LASTEXITCODE -ne 0){throw 'Could not clear the sparse attribute on the temporary boot VHDX.'}
    }
    Invoke-BootQemu -Arguments @('compare','-f','qcow2','-F','vhdx',$source,$bootDisk) -Name 'compare-boot-copy'
    $state.PayloadCompare='passed';Save-BootState
    $metadataRoot=Join-Path $work 'configdrive'
    $metadataDirectory=Join-Path $metadataRoot 'openstack\latest'
    New-Item -ItemType Directory -Path $metadataDirectory -Force|Out-Null
    $password='Test!'+[guid]::NewGuid().ToString('N')
    $metadata=@{uuid=[guid]::NewGuid().ToString();hostname='pve-bootcheck';name='pve-bootcheck';admin_pass=$password}
    [IO.File]::WriteAllText((Join-Path $metadataDirectory 'meta_data.json'),($metadata|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $oscdimg=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    if(-not(Test-Path -LiteralPath $oscdimg -PathType Leaf)){throw 'Install the official Microsoft ADK Deployment Tools (oscdimg) for boot verification.'}
    $configIso=Join-Path $work 'configdrive.iso'
    Invoke-BootNative -Executable $oscdimg -Arguments @('-n','-m','-lconfig-2',$metadataRoot,$configIso) -Name 'create-configdrive'
    $state.Phase='booting';Save-BootState
    Register-PveBuildVm -ContextPath $ResourceContextPath -Name $vmName -VhdPath $bootDisk
    $vm=New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $config.ram_size -SwitchName $config.external_switch -VHDPath $bootDisk
    $ownedVmId=$vm.Id
    Register-PveBuildVm -ContextPath $ResourceContextPath -Name $vmName -VhdPath $bootDisk -Id ([string]$ownedVmId)
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Set-VMProcessor -VM $vm -Count $config.cpu_count
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
    Add-VMDvdDrive -VM $vm -Path $configIso|Out-Null
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice (Get-VMHardDiskDrive -VM $vm|Select-Object -First 1)
    if ($Offline) { Disconnect-VMNetworkAdapter -VMName $vm.Name }
    Start-VM -VM $vm
    $credential=New-Object Management.Automation.PSCredential('Administrator',(ConvertTo-SecureString $password -AsPlainText -Force))
    $deadline=[DateTime]::UtcNow.AddMinutes(30)
    $guestProof=$null
    while(-not$guestProof -and [DateTime]::UtcNow -lt $deadline){
        try{
            $guestProof=Invoke-Command -VMId $ownedVmId -Credential $credential -ErrorAction Stop -ArgumentList @($software.InstallChrome,$software.InstallVSCode,$verifyActivation,$kmsEndpoint.Host,$kmsEndpoint.Port) -ScriptBlock {
                param($InstallChrome,$InstallVSCode,$VerifyActivation,$ExpectedKmsHost,$ExpectedKmsPort)
                $ErrorActionPreference='Stop'
                $administrator=Get-LocalUser|Where-Object {$_.SID.Value.EndsWith('-500')}
                $otherAdmin=Get-LocalUser -Name 'Admin' -ErrorAction SilentlyContinue
                $qga=Get-Service -Name 'qemu-ga'
                $cloudbase=Get-Service -Name 'cloudbase-init'
                $rdp=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections
                $nla=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication
                $proof=[ordered]@{
                    Boot='passed';AdministratorEnabled=$administrator.Enabled;ExtraAdminDisabled=(-not$otherAdmin -or -not$otherAdmin.Enabled)
                    QemuGuestAgent=($qga.StartType -eq 'Automatic');CloudbaseInit=($null -ne $cloudbase)
                    RdpEnabled=($rdp.fDenyTSConnections -eq 0);NlaEnabled=($nla.UserAuthentication -eq 1)
                    RdpListening=(@(Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue).Count -gt 0)
                    FirewallDisabled=(@(Get-NetFirewallProfile|Where-Object {$_.Enabled -ne 'False'}).Count -eq 0)
                    WindowsVersion=(Get-CimInstance Win32_OperatingSystem).Version
                }
                foreach($app in @(@{Name='Chrome';Selected=$InstallChrome;Path=(Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')},@{Name='VSCode';Selected=$InstallVSCode;Path=(Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe')})){
                    if($app.Selected){$proof[$app.Name+'Version']=(Get-Item -LiteralPath $app.Path).VersionInfo.ProductVersion.Trim()}
                }
                if(-not$proof.AdministratorEnabled -or -not$proof.ExtraAdminDisabled -or -not$proof.QemuGuestAgent -or -not$proof.CloudbaseInit -or -not$proof.RdpEnabled -or -not$proof.RdpListening -or -not$proof.NlaEnabled -or -not$proof.FirewallDisabled){throw 'Guest configuration has not passed all checks.'}
                if ($VerifyActivation) {
                    $activationPath=Join-Path $env:ProgramData 'PveImageBuilder\windows-activation.json'
                    if (-not (Test-Path -LiteralPath $activationPath -PathType Leaf)) { throw 'Waiting for the optional activation script to finish.' }
                    $activation=Get-Content -Raw -Encoding UTF8 -LiteralPath $activationPath | ConvertFrom-Json
                    if ($activation.SchemaVersion -ne 1 -or -not $activation.CompletedUtc -or
                        $activation.Outcome -notin @('Activated','AlreadyActivated','Skipped','Failed') -or
                        $activation.KmsHost -ine $ExpectedKmsHost -or $activation.KmsPort -ne $ExpectedKmsPort) { throw 'Optional activation diagnostics are incomplete or describe a different KMS endpoint.' }
                    $cloudbaseLog=Join-Path $env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log'
                    $cloudbaseText=Get-Content -Raw -LiteralPath $cloudbaseLog
                    if ($cloudbaseText -notmatch '30-WindowsActivation\.ps1" ended with exit code: 0(?:\s|$)' -or
                        $cloudbaseText -notmatch 'Plugins execution done') { throw 'Waiting for Cloudbase-Init LocalScripts to complete without requesting a reboot.' }
                    $licensing=Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
                    if ($licensing.KeyManagementServiceMachine -ine $ExpectedKmsHost -or
                        $licensing.KeyManagementServicePort -ne $ExpectedKmsPort) { throw 'The selected KMS settings were not reapplied after Sysprep.' }
                    $kmsProducts=@(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop |
                        Where-Object { $_.Description -match '\bVOLUME_KMSCLIENT\b' -and -not $_.LicenseIsAddon })
                    $proof.WindowsKmsClientInstalled=($kmsProducts.Count -gt 0)
                    $proof.KmsSettingsReapplied=$true
                    $proof.CloudbaseLocalScriptsCompleted=$true
                    # Failed and skipped activation are valid deployment outcomes, including offline boots.
                    $proof.WindowsActivation=$activation
                }
                [PSCustomObject]$proof
            }
        }catch{$state.LastProbeError=$_.Exception.Message;Save-BootState;Start-Sleep -Seconds 15}
    }
    if(-not$guestProof){throw 'The independent UEFI boot copy did not pass guest checks within 30 minutes.'}
    [IO.File]::WriteAllText((Join-Path $LogDirectory 'guest-proof.json'),($guestProof|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    try{Invoke-Command -VMId $ownedVmId -Credential $credential -ScriptBlock {Stop-Computer -Force} -ErrorAction Stop|Out-Null}catch{}
    $stopDeadline=[DateTime]::UtcNow.AddMinutes(2)
    while((Get-VM -Id $ownedVmId).State -ne 'Off' -and [DateTime]::UtcNow -lt $stopDeadline){Start-Sleep -Seconds 3}
    if((Get-VM -Id $ownedVmId).State -ne 'Off'){Stop-VM -VM (Get-VM -Id $ownedVmId) -TurnOff -Force}
    if((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne $state.SourceSHA256){throw 'The original QCOW2 changed during verification.'}
    $state.Phase='complete';$state.Boot='passed';$state.OriginalImageUnchanged=$true;$state.CompletedUtc=[DateTime]::UtcNow.ToString('o')
    $state.Remove('LastProbeError')
    $complete=$true
    Save-BootState
    [PSCustomObject]$state
}catch{$state.Phase='failed';$state.Error=$_.Exception.Message;Save-BootState;throw}
finally{
    if($ownedVmId){
        $ownedVm=Get-VM -Id $ownedVmId -ErrorAction SilentlyContinue
        if($ownedVm){if($ownedVm.State -ne 'Off'){Stop-VM -VM $ownedVm -TurnOff -Force};if($complete){Remove-VM -VM $ownedVm -Force}}
    }
}
