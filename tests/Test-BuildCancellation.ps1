[CmdletBinding()]
param([ValidateSet('Automatic','Interactive')][string]$Mode='Automatic')
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\Project.Common.ps1')
Assert-PowerShell51
. (Join-Path $repo 'scripts\Build.Cancellation.ps1')
function Assert-CancelTest { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-CancelFailure {
    param([scriptblock]$Action,[string]$Pattern)
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true; if ($_.Exception.Message -notmatch $Pattern) { throw } }
    Assert-CancelTest $failed ('Expected failure: '+$Pattern)
}
$fixture=Join-Path $repo ('local\cancellation tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'scripts\Build.Resources.ps1') -Destination (Join-Path $fixture 'scripts\Build.Resources.ps1')
$worker=Join-Path $fixture "dummy worker's `$literal.ps1"
$workerText=@'
[CmdletBinding(SupportsShouldProcess=$true)]
param($ConfigPath,[switch]$InternalWorker,$ResourceContextPath,[switch]$SkipBootVerification)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'scripts\Build.Resources.ps1')
$context=Get-PveBuildResources -ContextPath $ResourceContextPath
$request=Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$vhd=[IO.Path]::ChangeExtension($context.OutputPath,'.vhdx')
[IO.File]::WriteAllText($vhd,'New incomplete disk; fixture only.')
[IO.File]::WriteAllText($context.OutputPath,'New incomplete output; fixture only.')
$temporary=Join-Path $context.AssetsRoot 'work\owned temporary files'
Register-PveBuildDirectory -ContextPath $ResourceContextPath -Path $temporary
New-Item -ItemType Directory -Path $temporary | Out-Null
[IO.File]::WriteAllText((Join-Path $temporary 'boot-copy.vhdx'),'Boot copy fixture.')
[IO.File]::WriteAllText((Join-Path $temporary 'configdrive.iso'),'Generated ISO fixture.')
[IO.File]::WriteAllText((Join-Path $context.LogDirectory 'diagnostic.log'),'Keep this diagnostic log.')
$context=Get-PveBuildResources -ContextPath $ResourceContextPath
$context.VMs=@([PSCustomObject]@{Name=$request.VmName;Id=$request.VmId;VhdPath=$vhd;ExistedBefore=$false})
Save-PveBuildResources -ContextPath $ResourceContextPath -Context $context
if ($request.Action -eq 'success') {
    $context.Completed=$true
    Save-PveBuildResources -ContextPath $ResourceContextPath -Context $context
    [IO.File]::WriteAllText((Join-Path $context.LogDirectory 'status.json'),'{"Phase":"complete"}')
    exit 0
}
if ($request.Action -eq 'error') { throw 'Expected dummy build failure.' }
$native=New-Object Diagnostics.ProcessStartInfo
$native.FileName=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$native.Arguments='-NoProfile -Command "Start-Sleep -Seconds 120"'
$native.UseShellExecute=$false
$native.CreateNoWindow=$true
$child=[Diagnostics.Process]::Start($native)
[IO.File]::WriteAllText((Join-Path $context.LogDirectory 'child.pid'),[string]$child.Id)
[IO.File]::WriteAllText($request.ReadyPath,'ready')
Write-Host 'CANCEL_TEST_READY - 请按 Ctrl+C'
Start-Sleep -Seconds 120
'@
[IO.File]::WriteAllText($worker,$workerText,[Text.UTF8Encoding]::new($true))
& {
    $global:PveCancellationTestState=@{VMs=@{};Events=(New-Object 'System.Collections.Generic.List[string]');Answers=(New-Object 'System.Collections.Generic.Queue[string]');Reads=0;ReadyPath='';Deadline=[DateTime]::UtcNow.AddSeconds(30);Images=@{}}
    function Get-VM {
        param($Id,$Name,$ErrorAction)
        foreach ($vm in $global:PveCancellationTestState.VMs.Values) {
            if (($Id -and [string]$vm.Id -eq [string]$Id) -or ($Name -and $vm.Name -eq $Name)) { return $vm }
        }
    }
    function Get-VMHardDiskDrive { param($VM,$ErrorAction) [PSCustomObject]@{Path=$VM.DiskPath} }
    function Stop-VM {
        param($VM,[switch]$TurnOff,[switch]$Force,$ErrorAction)
        $global:PveCancellationTestState.Events.Add('stop:'+ $VM.Name)
        $VM.State='Off'
    }
    function Remove-VM {
        param($VM,[switch]$Force,$ErrorAction)
        $global:PveCancellationTestState.Events.Add('remove:'+ $VM.Name)
        $global:PveCancellationTestState.VMs.Remove([string]$VM.Id)
    }
    function Get-VHD { param($Path,$ErrorAction) [PSCustomObject]@{Attached=$true;Path=$Path} }
    function Get-Disk {
        [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject)
        process { [PSCustomObject]@{IsBoot=$false;IsSystem=$false} }
    }
    function Dismount-VHD { param($Path,$ErrorAction) $global:PveCancellationTestState.Events.Add('disk:'+ $Path) }
    function Get-DiskImage {
        param($ImagePath,$ErrorAction)
        [PSCustomObject]@{Attached=($global:PveCancellationTestState.Images.ContainsKey($ImagePath) -and $global:PveCancellationTestState.Images[$ImagePath])}
    }
    function Dismount-DiskImage { param($ImagePath,$ErrorAction) $global:PveCancellationTestState.Events.Add('iso:'+ $ImagePath);$global:PveCancellationTestState.Images[$ImagePath]=$false }
    if ($Mode -eq 'Automatic') {
        function Read-Host {
            param($Prompt)
            $global:PveCancellationTestState.Reads++
            if (-not $global:PveCancellationTestState.Answers.Count) { throw 'Unexpected cleanup prompt.' }
            $global:PveCancellationTestState.Answers.Dequeue()
        }
        function Test-PveBuildCancellationKey {
            if ([DateTime]::UtcNow -gt $global:PveCancellationTestState.Deadline) { throw 'Dummy worker startup timed out.' }
            return [IO.File]::Exists($global:PveCancellationTestState.ReadyPath)
        }
    }
    $checked=0
    foreach ($choice in @('default','no','retry','success','error')) {
        if ($Mode -eq 'Interactive' -and $choice -notin @('default','no')) { continue }
        $case=Join-Path $fixture $choice
        $assets=Join-Path $case 'assets'
        foreach ($directory in @('iso','output','custom-resources')) { New-Item -ItemType Directory -Path (Join-Path $assets $directory) -Force | Out-Null }
        $source=Join-Path $assets 'iso\install.wim'
        $iso=Join-Path $assets 'iso\virtio.iso'
        $oldImage=Join-Path $assets 'output\existing.qcow2'
        $installer=Join-Path $assets 'custom-resources\installer.exe'
        foreach ($file in @($source,$iso,$oldImage,$installer)) { [IO.File]::WriteAllText($file,'Existing user file; preserve.') }
        $output=Join-Path $assets "output\new disk's `$literal.qcow2"
        $ownedId=[guid]::NewGuid().ToString()
        $otherId=[guid]::NewGuid().ToString()
        $owned=[PSCustomObject]@{Name='owned-test-vm';Id=$ownedId;DiskPath=[IO.Path]::ChangeExtension($output,'.vhdx');State='Running'}
        $other=[PSCustomObject]@{Name='existing-user-vm';Id=$otherId;DiskPath=(Join-Path $assets 'output\existing.vhdx');State='Running'}
        $global:PveCancellationTestState.VMs=@{$ownedId=$owned;$otherId=$other}
        $global:PveCancellationTestState.Events.Clear()
        $global:PveCancellationTestState.Reads=0
        $global:PveCancellationTestState.Answers.Clear()
        $global:PveCancellationTestState.ReadyPath=Join-Path $case 'ready'
        $global:PveCancellationTestState.Deadline=[DateTime]::UtcNow.AddSeconds(30)
        $global:PveCancellationTestState.Images=@{$iso=$true}
        $action='wait'
        if ($choice -in @('success','error')) { $action=$choice }
        if ($choice -eq 'default') { $global:PveCancellationTestState.Answers.Enqueue('') }
        elseif ($choice -eq 'no') { $global:PveCancellationTestState.Answers.Enqueue('N') }
        elseif ($choice -eq 'retry') { $global:PveCancellationTestState.Answers.Enqueue('invalid');$global:PveCancellationTestState.Answers.Enqueue('Y') }
        $request=Join-Path $case 'request.json'
        [IO.File]::WriteAllText($request,(@{Action=$action;VmName=$owned.Name;VmId=$ownedId;ReadyPath=$global:PveCancellationTestState.ReadyPath}|ConvertTo-Json))
        $settings=[PSCustomObject]@{ProjectRoot=$case;AssetsRoot=$assets}
        $config=[PSCustomObject]@{wim_file_path=$source;virtio_iso_path=$iso;image_path=$output}
        if ($Mode -eq 'Interactive') { Write-Host ('INTERACTIVE_CASE='+$choice) }
        if ($choice -eq 'error') {
            Assert-CancelFailure { Invoke-PveControlledBuild -ScriptPath $worker -ConfigPath $request -Settings $settings -Config $config } '构建失败'
            Assert-CancelTest ($global:PveCancellationTestState.Reads -eq 0 -and (Test-Path -LiteralPath $output)) 'Ordinary failure prompted or deleted resources.'
        } else {
            $result=Invoke-PveControlledBuild -ScriptPath $worker -ConfigPath $request -Settings $settings -Config $config
            if ($choice -eq 'success') {
                Assert-CancelTest ($result.Phase -eq 'complete' -and $global:PveCancellationTestState.Reads -eq 0 -and (Test-Path -LiteralPath $output)) 'Successful build prompted or removed its output.'
            } else {
                $keep=($choice -eq 'no')
                Assert-CancelTest ($result.Phase -eq 'cancelled' -and $result.Cleanup -eq $(if($keep){'declined'}else{'complete'})) 'Cancellation decision was not recorded.'
                Assert-CancelTest ((Test-Path -LiteralPath $output) -eq $keep) 'Incomplete output cleanup does not match the decision.'
                Assert-CancelTest ((Test-Path -LiteralPath (Join-Path $assets 'work\owned temporary files')) -eq $keep) 'Temporary directory cleanup does not match the decision.'
                Assert-CancelTest (($global:PveCancellationTestState.VMs.ContainsKey($ownedId)) -eq $keep) 'Owned VM cleanup does not match the decision.'
                Assert-CancelTest ($other.State -eq 'Running' -and $global:PveCancellationTestState.VMs.ContainsKey($otherId)) 'Existing user VM was modified.'
                $log=Get-ChildItem -LiteralPath (Join-Path $assets 'logs\builds') -Directory | Select-Object -First 1
                $childId=[int][IO.File]::ReadAllText((Join-Path $log.FullName 'child.pid'))
                Assert-CancelTest (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Cancelled native child process remains running.'
                Assert-CancelTest (Test-Path -LiteralPath (Join-Path $log.FullName 'diagnostic.log')) 'Diagnostic log was removed.'
            }
        }
        foreach ($file in @($source,$iso,$oldImage,$installer)) { Assert-CancelTest ([IO.File]::ReadAllText($file) -eq 'Existing user file; preserve.') 'Existing source or image changed.' }
        Assert-CancelTest $global:PveCancellationTestState.Images[$iso] 'A pre-existing ISO mount was detached.'
        $checked++
    }
    # Registration rejects pre-existing files and VMs; metadata cannot widen deletion.
    $log=Get-ChildItem -LiteralPath (Join-Path $fixture 'no\assets\logs\builds') -Directory | Select-Object -First 1
    $contextPath=Join-Path $log.FullName 'resources.json'
    $context=Get-PveBuildResources -ContextPath $contextPath
    $existingTemporary=Join-Path $context.LogDirectory 'windows-pe\servicing.iso'
    New-Item -ItemType Directory -Path (Split-Path -Parent $existingTemporary) -Force | Out-Null
    [IO.File]::WriteAllText($existingTemporary,'Pre-existing file; do not adopt.')
    Assert-CancelFailure { Register-PveBuildFile -ContextPath $contextPath -Path $existingTemporary } 'Resource already exists'
    $originalOutput=$context.OutputPath
    $outside=Join-Path $fixture 'no\assets\output\existing.qcow2'
    $context.Files+= [PSCustomObject]@{Path=$outside;Kind='Temporary';ExistedBefore=$false}
    Save-PveBuildResources -ContextPath $contextPath -Context $context
    Assert-CancelFailure { Remove-PveOwnedBuildResources -ContextPath $contextPath } 'not an owned'
    Assert-CancelTest ([IO.File]::ReadAllText($outside) -eq 'Existing user file; preserve.') 'An unowned image was removed.'
    $context.Files=@($context.Files|Where-Object Path -ne $outside)
    $context.Completed=$true
    Save-PveBuildResources -ContextPath $contextPath -Context $context
    Assert-CancelFailure { Remove-PveOwnedBuildResources -ContextPath $contextPath } 'completed build'
    Assert-CancelTest (Test-Path -LiteralPath $originalOutput) 'Completed output was removed.'
    $context.Completed=$false
    Save-PveBuildResources -ContextPath $contextPath -Context $context
    Assert-CancelFailure { Register-PveBuildVm -ContextPath $contextPath -Name 'existing-user-vm' -VhdPath ([IO.Path]::ChangeExtension($context.OutputPath,'.vhdx')) } 'existing VM'
    $vmEntry=$context.VMs[0]
    $changedVm=[PSCustomObject]@{Name=$vmEntry.Name;Id=$vmEntry.Id;DiskPath=(Join-Path $fixture 'unowned.vhdx');State='Running'}
    $global:PveCancellationTestState.VMs=@{([string]$changedVm.Id)=$changedVm}
    $global:PveCancellationTestState.Events.Clear()
    Assert-CancelFailure { Remove-PveOwnedBuildResources -ContextPath $contextPath } 'exactly its owned disk'
    Assert-CancelTest ($changedVm.State -eq 'Running' -and $global:PveCancellationTestState.Events.Count -eq 0 -and (Test-Path -LiteralPath $originalOutput)) 'A VM with changed ownership was modified.'
    $changedVm.DiskPath=$vmEntry.VhdPath
    $protectedDirectory=Join-Path $fixture 'protected user directory'
    New-Item -ItemType Directory -Path $protectedDirectory | Out-Null
    $sentinel=Join-Path $protectedDirectory 'preserve.txt'
    [IO.File]::WriteAllText($sentinel,'Keep linked directory contents.')
    $ownedTemporary=Join-Path $context.AssetsRoot 'work\owned temporary files'
    New-Item -ItemType Junction -Path (Join-Path $ownedTemporary 'linked') -Target $protectedDirectory | Out-Null
    Assert-CancelFailure { Remove-PveOwnedBuildResources -ContextPath $contextPath } 'containing links'
    Assert-CancelTest ([IO.File]::ReadAllText($sentinel) -eq 'Keep linked directory contents.') 'Cleanup followed a directory junction.'
    $context.Directories=@()
    $context.VMs=@()
    $iso=$context.SourceIsos[0].Path
    $context.SourceIsos[0].AttachedBefore=$false
    $global:PveCancellationTestState.Images=@{$iso=$true}
    Save-PveBuildResources -ContextPath $contextPath -Context $context
    Remove-PveOwnedBuildResources -ContextPath $contextPath
    Assert-CancelTest (-not $global:PveCancellationTestState.Images[$iso] -and (Test-Path -LiteralPath $iso)) 'An owned ISO mount was not released, or its source was deleted.'
    [PSCustomObject]@{CancellationCases=$checked;DefaultYes='passed';Decline='preserved';NativeProcessTree='stopped';OtherVmsAndFiles='preserved';ChangedVmOwnership='rejected';DirectoryLinks='rejected';OwnedIsoMount='detached; source preserved';Logs='preserved';Mode=$Mode;HyperVOperations='mocked';Fixture=$fixture}
}
