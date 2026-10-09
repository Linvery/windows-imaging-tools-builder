$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\Project.Common.ps1')
Assert-PowerShell51
. (Join-Path $repo 'scripts\Configuration.Common.ps1')
. (Join-Path $repo 'scripts\Builder.Workflow.ps1')
function Assert-KmsTest { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-KmsFailure {
    param([scriptblock]$Action)
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true }
    Assert-KmsTest $failed 'Expected KMS validation failure.'
}
foreach ($case in @(
    @{Address='';Host='';Port=1688},
    @{Address='kms-default.cangshui.net';Host='kms-default.cangshui.net';Port=1688},
    @{Address=' kms.example.com:1689 ';Host='kms.example.com';Port=1689},
    @{Address='192.0.2.10';Host='192.0.2.10';Port=1688},
    @{Address='[2001:db8::10]:1689';Host='2001:db8::10';Port=1689},
    @{Address='[2001:db8::10]';Host='2001:db8::10';Port=1688},
    @{Address='2001:db8::10';Host='2001:db8::10';Port=1688}
)) {
    $endpoint=ConvertTo-PveKmsEndpoint -Address $case.Address
    Assert-KmsTest ($endpoint.Address -ceq $case.Address.Trim() -and $endpoint.Host -ceq $case.Host -and $endpoint.Port -eq $case.Port) 'KMS host or port parsed incorrectly.'
}
foreach ($address in @('https://kms.example.com','kms.example.com/path','kms.example.com:0','kms.example.com:65536','kms.example.com:999999999999','kms.example.com:abc','kms host','[kms.example.com]:1688',"kms.example.com`nother",'kms.example.com;whoami')) {
    Assert-KmsFailure { ConvertTo-PveKmsEndpoint -Address $address }
}
& {
    $script:kmsAnswers=New-Object 'System.Collections.Generic.Queue[string]'
    function Read-Host {
        param($Prompt)
        if (-not $script:kmsAnswers.Count) { throw 'KMS test input exhausted.' }
        $script:kmsAnswers.Dequeue()
    }
    function Write-Host { param($Object,$ForegroundColor) }
    $script:kmsAnswers.Enqueue('')
    Assert-KmsTest ((Read-BuilderKmsServer).Address -ceq 'kms-default.cangshui.net') 'Default KMS choice changed.'
    foreach ($answer in @('2','')) { $script:kmsAnswers.Enqueue($answer) }
    Assert-KmsTest ((Read-BuilderKmsServer).Address -ceq '') 'Explicit blank was replaced by the default server.'
    foreach ($answer in @('2','https://invalid',' kms.example.com:1689 ')) { $script:kmsAnswers.Enqueue($answer) }
    Assert-KmsTest ((Read-BuilderKmsServer).Address -ceq 'kms.example.com:1689') 'Manual KMS input did not retry or trim.'
    $script:kmsAnswers.Enqueue('Q')
    Assert-KmsFailure { Read-BuilderKmsServer }
    foreach ($answer in @('2','Q')) { $script:kmsAnswers.Enqueue($answer) }
    Assert-KmsFailure { Read-BuilderKmsServer }
}
$fixture=Join-Path $repo ('local\kms settings tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
foreach ($directory in @('scripts','config','resources','local','assets\iso','assets\custom-resources','assets\output','LocalScripts')) { New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force | Out-Null }
foreach ($file in @('New-ImageConfig.ps1','scripts\Project.Common.ps1','scripts\Configuration.Common.ps1','scripts\Package.Validation.ps1','scripts\ProductKeys.Common.ps1','scripts\Software.Selection.ps1','config\Kms.ClientKeys.psd1','config\image.example.ini','resources\Apply-KmsSettings.ps1','resources\Activate-Windows.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo $file) -Destination (Join-Path $fixture $file)
}
[IO.File]::WriteAllText((Join-Path $fixture 'local\settings.json'),(@{ProjectRoot=$fixture;AssetsRoot=(Join-Path $fixture 'assets')}|ConvertTo-Json))
foreach ($file in @('assets\iso\Windows.iso','assets\iso\virtio-win.iso','assets\custom-resources\virtio-win-guest-tools.exe')) { [IO.File]::WriteAllText((Join-Path $fixture $file),'Fixture; never used to build an image.') }
$configurations=@()
foreach ($address in @($null,'kms.example.com:1689','')) {
    $parameters=@{WimPath=(Join-Path $fixture 'assets\iso\Windows.iso');ProductKeyMode='Kms';OutputPath=(Join-Path $fixture ('assets\output\image-'+$configurations.Count+'.qcow2'));ConfigPath=(Join-Path $fixture ('local\image-'+$configurations.Count+'.ini'));SkipChrome=$true;SkipVSCode=$true}
    if ($null -ne $address) { $parameters.KmsServer=$address }
    $result=& (Join-Path $fixture 'New-ImageConfig.ps1') @parameters
    $selection=Get-GuestSoftwareSelection -ResourceRoot $result.StagedResources
    $expected=$address
    if ($null -eq $expected) { $expected='kms-default.cangshui.net' }
    Assert-KmsTest ($selection.KmsServer -ceq $expected -and $result.KmsServer -ceq $expected) 'KMS address did not survive configuration staging.'
    Assert-KmsTest (Test-Path -LiteralPath (Join-Path $result.StagedResources 'Apply-KmsSettings.ps1')) 'Guest KMS script was not staged.'
    Assert-KmsTest (Test-Path -LiteralPath (Join-Path $result.StagedResources 'Activate-Windows.ps1')) 'Guest activation script was not staged.'
    $configurations+=@($result)
}
# Preserve old configurations without silently adding a public KMS endpoint.
$legacy=@{SchemaVersion=1;InstallChrome=$false;InstallVSCode=$false}
$selectionPath=Join-Path $fixture 'resources\software-selection.json'
[IO.File]::WriteAllText($selectionPath,($legacy|ConvertTo-Json))
Assert-KmsTest (-not (Get-GuestSoftwareSelection -ResourceRoot (Join-Path $fixture 'resources')).KmsServer) 'Legacy resources acquired a KMS server.'
$legacy.KmsServer=$false
[IO.File]::WriteAllText($selectionPath,($legacy|ConvertTo-Json))
Assert-KmsFailure { Get-GuestSoftwareSelection -ResourceRoot (Join-Path $fixture 'resources') }
$legacy.KmsServer='https://invalid'
[IO.File]::WriteAllText($selectionPath,($legacy|ConvertTo-Json))
Assert-KmsFailure { Get-GuestSoftwareSelection -ResourceRoot (Join-Path $fixture 'resources') }

$guestResources=Join-Path $fixture 'resources'
$localScripts=Join-Path $fixture 'LocalScripts'
Copy-Item -LiteralPath (Join-Path $repo 'scripts\Software.Selection.ps1') -Destination (Join-Path $guestResources 'Software.Selection.ps1')
foreach ($name in @('Apply-GuestNetworkSettings.ps1','Install-ManagedAdministrator.ps1')) { [IO.File]::WriteAllText((Join-Path $guestResources $name),'# Other guest actions are intentionally omitted in this fixture.') }
$hook=[IO.File]::ReadAllText((Join-Path $repo 'hooks\RunAfterCloudbaseInitInstall.ps1'))
$hook=$hook.Replace('C:\UnattendResources\CustomResources',$guestResources)
$hook=$hook.Replace('C:\ProgramData\PveImageBuilder',(Join-Path $fixture 'Diagnostics'))
$hook=$hook.Replace("Join-Path `$env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init\LocalScripts'",("'"+$localScripts+"'"))
$hook=$hook.Replace('exit 0','return 0').Replace('exit 1','return 1')
$guestHook=[scriptblock]::Create($hook)
& {
    $global:PveKmsSettingsTest=@{Calls=(New-Object 'System.Collections.Generic.List[object]');ReturnCode=0;ReturnMode='Object';ApplySettings=$true;Host='';Port=0}
    function Write-Host { param($Object,$ForegroundColor) }
    function Test-Path {
        param($LiteralPath,$PathType)
        if ($LiteralPath -eq 'C:\UnattendResources\config.ini') { return $true }
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
    }
    function Get-Service { param($Name,$ErrorAction) [PSCustomObject]@{Name=$Name} }
    function Set-Service { param($Name,$StartupType) }
    function Get-CimInstance {
        param($ClassName,$ErrorAction)
        Assert-KmsTest ($ClassName -eq 'SoftwareLicensingService') 'Unexpected guest CIM query.'
        [PSCustomObject]@{ClassName=$ClassName;KeyManagementServiceMachine=$global:PveKmsSettingsTest.Host;KeyManagementServicePort=$global:PveKmsSettingsTest.Port}
    }
    function Invoke-CimMethod {
        param($InputObject,$MethodName,$Arguments,$ErrorAction)
        Assert-KmsTest ($MethodName -in @('SetKeyManagementServiceMachine','SetKeyManagementServicePort')) 'An activation or unexpected licensing method was called.'
        $global:PveKmsSettingsTest.Calls.Add([PSCustomObject]@{Method=$MethodName;Arguments=$Arguments})
        if ($global:PveKmsSettingsTest.ApplySettings -and $global:PveKmsSettingsTest.ReturnCode -eq 0) {
            if ($MethodName -eq 'SetKeyManagementServiceMachine') { $global:PveKmsSettingsTest.Host=$Arguments.MachineName }
            else { $global:PveKmsSettingsTest.Port=$Arguments.PortNumber }
        }
        switch ($global:PveKmsSettingsTest.ReturnMode) {
            'Object' { [PSCustomObject]@{ReturnValue=$global:PveKmsSettingsTest.ReturnCode} }
            'Scalar' { [uint32]$global:PveKmsSettingsTest.ReturnCode }
            'Missing' { [PSCustomObject]@{} }
            'NullValue' { [PSCustomObject]@{ReturnValue=$null} }
            'Null' { $null }
        }
    }
    # Blank and legacy choices must not call Windows licensing or create startup scripts.
    foreach ($selection in @(@{SchemaVersion=1;InstallChrome=$false;InstallVSCode=$false;KmsServer=''},@{SchemaVersion=1;InstallChrome=$false;InstallVSCode=$false})) {
        [IO.File]::WriteAllText($selectionPath,($selection|ConvertTo-Json))
        Assert-KmsTest ((& $guestHook) -eq 0 -and $global:PveKmsSettingsTest.Calls.Count -eq 0) 'Blank/legacy choice configured KMS.'
        Assert-KmsTest (-not (Test-Path -LiteralPath (Join-Path $localScripts '20-KmsSettings.ps1'))) 'Blank/legacy choice created a KMS startup script.'
        Assert-KmsTest (-not (Test-Path -LiteralPath (Join-Path $localScripts '30-WindowsActivation.ps1'))) 'Blank/legacy choice created an activation startup script.'
    }
    foreach ($result in $configurations[0..1]) {
        Copy-Item -LiteralPath (Join-Path $result.StagedResources 'software-selection.json') -Destination $selectionPath -Force
        $global:PveKmsSettingsTest.Calls.Clear()
        Assert-KmsTest ((& $guestHook) -eq 0) 'Guest hook failed to configure KMS.'
        Assert-KmsTest ((Get-FileHash -LiteralPath (Join-Path $localScripts '30-WindowsActivation.ps1')).Hash -eq
            (Get-FileHash -LiteralPath (Join-Path $guestResources 'Activate-Windows.ps1')).Hash) 'The first-boot activation script was not copied intact.'
        $endpoint=ConvertTo-PveKmsEndpoint -Address $result.KmsServer
        Assert-KmsTest ($global:PveKmsSettingsTest.Calls.Count -eq 2 -and $global:PveKmsSettingsTest.Calls[0].Arguments.MachineName -eq $endpoint.Host -and $global:PveKmsSettingsTest.Calls[1].Arguments.PortNumber -eq $endpoint.Port) 'Guest licensing received the wrong host or port.'
        $global:PveKmsSettingsTest.Calls.Clear()
        & (Join-Path $localScripts '20-KmsSettings.ps1')
        Assert-KmsTest ($global:PveKmsSettingsTest.Calls.Count -eq 2 -and $global:PveKmsSettingsTest.Calls[0].Arguments.MachineName -eq $endpoint.Host) 'First-boot script did not reapply the configured KMS host.'
    }
    foreach ($returnMode in @('Null','Missing','NullValue','Scalar')) {
        $global:PveKmsSettingsTest.ReturnMode=$returnMode
        $global:PveKmsSettingsTest.Host='';$global:PveKmsSettingsTest.Port=0
        & (Join-Path $localScripts '20-KmsSettings.ps1')
        Assert-KmsTest ($global:PveKmsSettingsTest.Host -eq 'kms.example.com' -and $global:PveKmsSettingsTest.Port -eq 1689) 'A successful licensing method with no ReturnValue was rejected.'
    }
    $global:PveKmsSettingsTest.ReturnMode='Null'
    $global:PveKmsSettingsTest.ApplySettings=$false
    $global:PveKmsSettingsTest.Host='';$global:PveKmsSettingsTest.Port=0
    Assert-KmsFailure { & (Join-Path $localScripts '20-KmsSettings.ps1') }
    $global:PveKmsSettingsTest.ApplySettings=$true
    $global:PveKmsSettingsTest.ReturnMode='Scalar'
    $global:PveKmsSettingsTest.ReturnCode=5
    Assert-KmsFailure { & (Join-Path $localScripts '20-KmsSettings.ps1') }
    $global:PveKmsSettingsTest.ReturnMode='Object'
    Assert-KmsFailure { & (Join-Path $localScripts '20-KmsSettings.ps1') }
    Assert-KmsTest ((& $guestHook 2>$null) -eq 1) 'Guest hook ignored a licensing configuration failure.'
    $failureReport=Get-Content -Raw -LiteralPath (Join-Path $fixture 'Diagnostics\post-cloudbase-init-error.json') | ConvertFrom-Json
    Assert-KmsTest ($failureReport.Stage -eq 'ApplyKmsSettings' -and $failureReport.Message -match 'SetKeyManagementServiceMachine returned 5' -and $failureReport.ScriptStackTrace) 'Guest hook did not preserve the original licensing failure and stage.'
    $global:PveKmsSettingsTest.ReturnCode=0
    [IO.File]::WriteAllText((Join-Path $localScripts 'kms-settings.json'),(@{SchemaVersion=1;Host='https://invalid';Port=1688}|ConvertTo-Json))
    $global:PveKmsSettingsTest.Calls.Clear()
    Assert-KmsFailure { & (Join-Path $localScripts '20-KmsSettings.ps1') }
    Assert-KmsTest ($global:PveKmsSettingsTest.Calls.Count -eq 0) 'Invalid guest settings reached Windows licensing.'
    $activationTarget=Join-Path $localScripts '30-WindowsActivation.ps1'
    $originalActivation=[IO.File]::ReadAllText($activationTarget)
    try {
        [IO.File]::WriteAllText($activationTarget,'# Pre-existing user script must be preserved.')
        Assert-KmsTest ((& $guestHook 2>$null) -eq 1) 'Guest hook overwrote a different activation LocalScript.'
        Assert-KmsTest ([IO.File]::ReadAllText($activationTarget) -eq '# Pre-existing user script must be preserved.') 'A pre-existing activation script was modified.'
        $failureReport=Get-Content -Raw -LiteralPath (Join-Path $fixture 'Diagnostics\post-cloudbase-init-error.json') | ConvertFrom-Json
        Assert-KmsTest ($failureReport.Stage -eq 'StageWindowsActivation' -and $failureReport.Message -match 'refusing to overwrite') 'Activation staging failure was not diagnosed.'
    }
    finally { [IO.File]::WriteAllText($activationTarget,$originalActivation,[Text.UTF8Encoding]::new($false)) }
}
[PSCustomObject]@{TwoOptionMenu='passed';DefaultCustomBlank='passed';InputValidation='passed';IndependentConfigurations=$configurations.Count;GuestAndFirstBoot='passed';CimReturnShapes='passed';ReadbackVerification='passed';FailureHandling='passed';LicensingCalls='mocked; no activation request'}
