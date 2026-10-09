[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Project.Common.ps1')
Assert-PowerShell51
$dependencies=Get-BuildDependencies
. (Join-Path $root 'scripts\Builder.Workflow.ps1')
function Assert-EnvironmentFailure {
    param([scriptblock]$Action,[string]$Pattern)
    $failed=$false
    try { & $Action | Out-Null }
    catch { $failed=$true; if ($_.Exception.Message -notmatch $Pattern) { throw } }
    if (-not $failed) { throw ('Expected environment failure: '+$Pattern) }
}
& {
    $global:PveEnvironmentTestState=@{}
    $global:PveEnvironmentTestState.Mode='ok'
    $global:PveEnvironmentTestState.Switches=@([PSCustomObject]@{Name='external';SwitchType='External'})
    $global:PveEnvironmentTestState.Prompts=0
    $oscdimg=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    function Assert-PowerShell51 { if ($global:PveEnvironmentTestState.Mode -eq 'powershell') { throw 'Wrong shell.' } }
    function Assert-Administrator { if ($global:PveEnvironmentTestState.Mode -eq 'administrator') { throw 'Not elevated.' } }
    function Get-Module {
        param($Name,[switch]$ListAvailable)
        if ($Name -eq 'Hyper-V' -and $ListAvailable) {
            if ($global:PveEnvironmentTestState.Mode -ne 'module_missing') { [PSCustomObject]@{Name='Hyper-V'} }
            return
        }
        Microsoft.PowerShell.Core\Get-Module -Name $Name
    }
    function Import-Module {
        param($Name,$ErrorAction)
        if ($Name -ne 'Hyper-V') { throw 'Unexpected module import.' }
        if ($global:PveEnvironmentTestState.Mode -eq 'module_broken') { throw 'Broken module.' }
    }
    function Get-Service {
        param($Name,$ErrorAction)
        if ($Name -ne 'vmms') { throw 'Unexpected service query.' }
        if ($global:PveEnvironmentTestState.Mode -eq 'service_missing') { return }
        $status='Running'
        if ($global:PveEnvironmentTestState.Mode -eq 'service_stopped') { $status='Stopped' }
        [PSCustomObject]@{Name=$Name;Status=$status}
    }
    function Get-CimInstance {
        param($ClassName,$ErrorAction)
        if ($ClassName -ne 'Win32_ComputerSystem') { throw 'Unexpected hardware query.' }
        [PSCustomObject]@{HypervisorPresent=($global:PveEnvironmentTestState.Mode -ne 'hypervisor');NumberOfLogicalProcessors=8;TotalPhysicalMemory=32GB}
    }
    function Get-VMHost {
        param($ErrorAction)
        if ($global:PveEnvironmentTestState.Mode -eq 'permission') { throw 'Access denied.' }
        [PSCustomObject]@{Name='Mock build host'}
    }
    function Get-VMSwitch { param($ErrorAction) $global:PveEnvironmentTestState.Switches }
    function Test-Path {
        param($LiteralPath,$PathType)
        if ($LiteralPath -eq $oscdimg) { return $global:PveEnvironmentTestState.Mode -ne 'adk' }
        if ($PathType) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType }
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
    }
    function Get-Item {
        param($LiteralPath)
        if ($LiteralPath -eq $oscdimg) { return [PSCustomObject]@{VersionInfo=[PSCustomObject]@{FileVersion='10.0.26100.1'}} }
        Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
    }
    function Read-Host { param($Prompt) $global:PveEnvironmentTestState.Prompts++; throw 'An invalid environment must stop before prompting.' }
    $cases=@{
        powershell='Windows PowerShell 5.1';administrator='管理员权限';module_missing='启用 Hyper-V';
        module_broken='无法加载 Hyper-V';service_missing='vmms';service_stopped='vmms';
        hypervisor='BIOS/UEFI';permission='无法管理 Hyper-V';adk='Deployment Tools.*https://learn.microsoft.com'
    }
    foreach ($mode in $cases.Keys) {
        $global:PveEnvironmentTestState.Mode=$mode
        Assert-EnvironmentFailure { Get-BuilderHost -AllowMissingExternalSwitch } $cases[$mode]
    }
    $global:PveEnvironmentTestState.Mode='ok'
    $hostInfo=Get-BuilderHost
    if ($hostInfo.Switches[0].Name -ne 'external' -or $hostInfo.LogicalProcessors -ne 8 -or $hostInfo.MemoryGiB -ne 32 -or -not $hostInfo.Adk.OscdimgPath) { throw 'Environment inventory is incorrect.' }
    $global:PveEnvironmentTestState.Switches=@()
    if (@((Get-BuilderHost -AllowMissingExternalSwitch).Switches).Count) { throw 'Missing switch was invented.' }
    Assert-EnvironmentFailure { Get-BuilderHost } '外部交换机'
    $global:PveEnvironmentTestState.Switches=@([PSCustomObject]@{Name='external';SwitchType='External'})
    foreach ($mode in @('module_missing','adk')) {
        $global:PveEnvironmentTestState.Mode=$mode
        Assert-EnvironmentFailure { Invoke-ImageBuilderWizard } $cases[$mode]
    }
    if ($global:PveEnvironmentTestState.Prompts) { throw 'Wizard continued to ask for resources in an invalid environment.' }

    # Exercise the actual -WhatIf entry in an isolated fixture. Native environment
    # queries are mocked above; any attempt to build or mount an ISO is rejected.
    $fixture=Join-Path $root ('local\environment tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
    foreach ($directory in @('scripts','config','local','assets','resources')) { New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force | Out-Null }
    foreach ($file in @('Build-Image.ps1','scripts\Build.Validation.ps1','scripts\Builder.Workflow.ps1','scripts\Configuration.Common.ps1','scripts\Package.Validation.ps1','scripts\ProductKeys.Common.ps1','scripts\Software.Selection.ps1','config\Kms.ClientKeys.psd1')) {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $fixture $file)
    }
    $common=@'
$ProjectRoot=Split-Path -Parent $PSScriptRoot
function Get-ProjectSettings { Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'local\settings.json') | ConvertFrom-Json }
function Get-BuildDependencies { Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'local\dependencies.json') | ConvertFrom-Json }
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'scripts\Project.Common.ps1'),$common)
    $import=@'
param($Settings)
function Get-WindowsImageConfig { param($ConfigFilePath) Get-Content -Raw -LiteralPath $ConfigFilePath | ConvertFrom-Json }
function Get-WimFileImagesInfo { param($WimFilePath) [PSCustomObject]@{ImageName='Windows 11 Pro';ImageVersion=[version]'10.0.26100.1'} }
function New-WindowsOnlineImage { throw 'Preflight must never start a build.' }
function Mount-DiskImage { throw 'This WIM-only test must not mount an ISO.' }
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'scripts\Import-ImagingTools.ps1'),$import)
    foreach ($file in @('install.wim','Windows.iso','virtio.iso','qemu-img.exe')) { [IO.File]::WriteAllText((Join-Path $fixture ('assets\'+$file)),'Fixture; never executed.') }
    [IO.File]::WriteAllText((Join-Path $fixture 'resources\virtio-win-guest-tools.exe'),'Unsigned fixture; filename only.')
    [IO.File]::WriteAllText((Join-Path $fixture 'resources\software-selection.json'),(@{SchemaVersion=1;InstallChrome=$false;InstallVSCode=$false;ServicingIsoPath=(Join-Path $fixture 'assets\Windows.iso')}|ConvertTo-Json))
    $dependencies.Qemu.ExecutableSHA256=(Get-FileHash -LiteralPath (Join-Path $fixture 'assets\qemu-img.exe')).Hash
    [IO.File]::WriteAllText((Join-Path $fixture 'local\dependencies.json'),($dependencies|ConvertTo-Json -Depth 4))
    $manifest=Join-Path $fixture 'local\tool.json'
    [IO.File]::WriteAllText($manifest,(@{Version=$dependencies.Qemu.Version;PublishedHashVerified=$true;ExecutablePath=(Join-Path $fixture 'assets\qemu-img.exe')}|ConvertTo-Json))
    $settings=@{ProjectRoot=$fixture;AssetsRoot=(Join-Path $fixture 'assets');UpstreamRoot=(Join-Path $root 'vendor\windows-imaging-tools');GitPath=(Get-Command git.exe).Source;QemuManifestPath=$manifest}
    [IO.File]::WriteAllText((Join-Path $fixture 'local\settings.json'),($settings|ConvertTo-Json))
    $config=@{wim_file_path=(Join-Path $fixture 'assets\install.wim');virtio_iso_path=(Join-Path $fixture 'assets\virtio.iso');image_path=(Join-Path $fixture 'assets\preflight.qcow2');virtual_disk_format='QCOW2';image_type='KVM';disk_layout='UEFI';custom_resources_path=(Join-Path $fixture 'resources');external_switch='external';cpu_count=4;ram_size=4GB;disk_size=64GB;image_name='Windows 11 Pro'}
    $configPath=Join-Path $fixture 'local\config.json'
    [IO.File]::WriteAllText($configPath,($config|ConvertTo-Json))
    function Get-PSDrive {
        param($Name,$PSProvider)
        $free=1TB
        if ($global:PveEnvironmentTestState.Mode -eq 'disk_space') { $free=1GB }
        [PSCustomObject]@{Free=$free}
    }
    foreach ($mode in @('module_missing','adk')) {
        $global:PveEnvironmentTestState.Mode=$mode
        Assert-EnvironmentFailure { & (Join-Path $fixture 'Build-Image.ps1') -ConfigPath $configPath -WhatIf } $cases[$mode]
    }
    $global:PveEnvironmentTestState.Mode='ok'
    $preflight=& (Join-Path $fixture 'Build-Image.ps1') -ConfigPath $configPath -WhatIf
    if ($preflight.HostChecks -ne 'passed') { throw 'WhatIf skipped host checks.' }
    $config.cpu_count=9
    [IO.File]::WriteAllText($configPath,($config|ConvertTo-Json))
    Assert-EnvironmentFailure { & (Join-Path $fixture 'Build-Image.ps1') -ConfigPath $configPath -WhatIf } 'CPU or memory'
    $config.cpu_count=4
    $config.ram_size=64GB
    [IO.File]::WriteAllText($configPath,($config|ConvertTo-Json))
    Assert-EnvironmentFailure { & (Join-Path $fixture 'Build-Image.ps1') -ConfigPath $configPath -WhatIf } 'CPU or memory'
    $config.ram_size=4GB
    [IO.File]::WriteAllText($configPath,($config|ConvertTo-Json))
    $global:PveEnvironmentTestState.Mode='disk_space'
    Assert-EnvironmentFailure { & (Join-Path $fixture 'Build-Image.ps1') -ConfigPath $configPath -WhatIf } '空间不足'
    $global:PveEnvironmentTestState.Mode='ok'
    $config.image_name='Missing edition'
    [IO.File]::WriteAllText($configPath,($config|ConvertTo-Json))
    Assert-EnvironmentFailure { & (Join-Path $fixture 'Build-Image.ps1') -ConfigPath $configPath -WhatIf } 'edition was not found'
    if (Test-Path -LiteralPath $config.image_path) { throw 'Preflight created an image.' }
    if (Test-Path -LiteralPath (Join-Path $fixture 'assets\logs')) { throw 'Preflight entered the build stage.' }
    [PSCustomObject]@{EnvironmentFailures=$cases.Count;MissingSwitch='prompt allowed only after environment checks';Wizard='stops before resources';WhatIfHostChecks='passed; missing dependencies rejected';CpuMemoryDiskAndEdition='checked; invalid inputs rejected';BuildSideEffects='none';EnvironmentQueries='mocked'}
}
