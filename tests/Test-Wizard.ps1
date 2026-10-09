[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Project.Common.ps1')
Assert-PowerShell51
. (Join-Path $root 'scripts\Configuration.Common.ps1')
. (Join-Path $root 'scripts\Builder.Workflow.ps1')
. (Join-Path $root 'scripts\Software.Selection.ps1')
function Assert-Test { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action,[string]$Pattern)
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown=$true; if ($_.Exception.Message -notmatch $Pattern) { throw } }
    Assert-Test $thrown ('Expected failure: ' + $Pattern)
}
$fixture = Join-Path $root ('local\wizard tests ' + [guid]::NewGuid().ToString('N').Substring(0,8))
foreach ($directory in @('scripts','resources','config','local','assets\iso','assets\custom-resources','assets\output')) { New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force | Out-Null }
foreach ($name in @('New-ImageConfig.ps1','scripts\Project.Common.ps1','scripts\Build.Dependencies.psd1','scripts\Configuration.Common.ps1','scripts\Package.Validation.ps1','scripts\ProductKeys.Common.ps1','scripts\Software.Selection.ps1','config\Kms.ClientKeys.psd1','config\image.example.ini')) { Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $fixture $name) }
[IO.File]::WriteAllText((Join-Path $fixture 'resources\guest-marker.ps1'),'# fixture')
foreach ($name in @('chrome-enterprise64.msi','VSCodeSetup-test.exe','virtio-win-guest-tools.exe')) {
    $path = Join-Path $fixture ('assets\custom-resources\' + $name)
    [IO.File]::WriteAllText($path,('test data; never executed: ' + $name))
}
function Get-AuthenticodeSignature {
    param($LiteralPath)
    $publisher='Microsoft Corporation'
    if ([IO.Path]::GetExtension($LiteralPath) -eq '.msi') { $publisher='Google LLC' }
    $certificate=[PSCustomObject]@{Publisher=$publisher}
    $certificate | Add-Member -MemberType ScriptMethod -Name GetNameInfo -Value {param($Type,$ForIssuer) $this.Publisher}
    $status='Valid'
    if ([IO.File]::ReadAllText($LiteralPath) -eq 'corrupted fixture') { $status='HashMismatch' }
    [PSCustomObject]@{Status=$status;SignerCertificate=$certificate}
}
$fixtureSettings = [PSCustomObject]@{ProjectRoot=$fixture;AssetsRoot=(Join-Path $fixture 'assets');UpstreamRoot=(Join-Path $root 'vendor\windows-imaging-tools');QemuManifestPath=(Join-Path $fixture 'absent-tool.json')}
[IO.File]::WriteAllText((Join-Path $fixture 'local\settings.json'),($fixtureSettings|ConvertTo-Json))
foreach ($name in @('install.wim','Windows.iso','virtio-win.iso')) { [IO.File]::WriteAllText((Join-Path $fixture ('assets\iso\'+$name)),'Fixture; not a real ISO or WIM.') }
Assert-Test ((Find-WindowsInstallerIso -ProjectRoot $fixture -AssetsRoot $fixtureSettings.AssetsRoot) -eq (Join-Path $fixture 'assets\iso\Windows.iso')) 'Existing asset ISO fallback changed.'
New-Item -ItemType Directory -Path (Join-Path $fixture 'data\iso') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $fixture 'data\iso\Windows.iso'),'Source selection fixture.')
[IO.File]::WriteAllText((Join-Path $fixture 'data\iso\virtio-win.iso'),'Driver ISO selection fixture.')
Assert-Test ((Find-WindowsInstallerIso -ProjectRoot $fixture -AssetsRoot $fixtureSettings.AssetsRoot) -eq (Join-Path $fixture 'data\iso\Windows.iso')) 'The data Windows ISO was not preferred.'
Assert-Test ((Find-VirtioInstallerIso -ProjectRoot $fixture -AssetsRoot $fixtureSettings.AssetsRoot) -eq (Join-Path $fixture 'data\iso\virtio-win.iso')) 'The data VirtIO ISO was not preferred.'
Import-Module (Join-Path $root 'vendor\windows-imaging-tools\Config.psm1') -Force
$checked = 0
foreach ($skipChrome in @($false,$true)) {
    foreach ($skipCode in @($false,$true)) {
        $parameters = @{WimPath=(Join-Path $fixture 'assets\iso\Windows.iso');OutputPath=(Join-Path $fixture ('assets\output\disk $literal-' + $checked + '.qcow2'));SwitchName='external $literal';CpuCount=2;RamGiB=4;DiskGiB=96;TimeZone='UTC';ImageName='Windows 11 Pro';InstallUpdates=$true;SkipChrome=$skipChrome;SkipVSCode=$skipCode}
        $result = & (Join-Path $fixture 'New-ImageConfig.ps1') @parameters
        $selection = Get-GuestSoftwareSelection -ResourceRoot $result.StagedResources
        Assert-Test ($selection.InstallChrome -eq (-not $skipChrome) -and $selection.InstallVSCode -eq (-not $skipCode)) 'Selection did not reach guest resources.'
        Assert-Test ((Test-Path -LiteralPath (Join-Path $result.StagedResources 'chrome-enterprise64.msi')) -eq (-not $skipChrome)) 'Chrome staging is incorrect.'
        Assert-Test ((Test-Path -LiteralPath (Join-Path $result.StagedResources 'VSCodeSetup-x64.exe')) -eq (-not $skipCode)) 'VSCode staging is incorrect.'
        Assert-Test (Test-Path -LiteralPath (Join-Path $result.StagedResources 'Package.Validation.ps1')) 'Guest signature validator was not staged.'
        Assert-Test (-not ($selection.Packages | Where-Object { $_.PSObject.Properties['Version'] -or $_.PSObject.Properties['SHA256'] })) 'Software selection still pins an application version or hash.'
        Assert-Test (Test-Path -LiteralPath (Join-Path $result.StagedResources 'virtio-win-guest-tools.exe')) 'Required VirtIO package was omitted.'
        $parsed = Get-WindowsImageConfig -ConfigFilePath $result.ConfigPath
        Assert-Test ($parsed.msi_path -eq (Join-Path $fixtureSettings.AssetsRoot 'assets\CloudbaseInitSetup_Stable_x64.msi')) 'Cloudbase-Init cache path did not follow the selected asset directory.'
        Assert-Test ($parsed.image_path -eq $parameters.OutputPath -and $parsed.external_switch -eq $parameters.SwitchName) 'Literal path characters were changed.'
        Assert-Test ($parsed.wim_file_path -eq $parameters.WimPath -and $parsed.image_name -eq 'Windows 11 Pro') 'Source/edition did not reach the INI.'
        Assert-Test ($parsed.disk_size -eq 96GB -and $parsed.ram_size -eq 4GB -and $parsed.install_updates -eq $true) 'Build parameters were not parsed.'
        Assert-Test (([IO.File]::ReadAllBytes($result.ConfigPath))[0] -eq [byte][char]'[') 'Generated INI has a BOM.'
        Assert-Test ($result.BuildPassword -notmatch 'Build!') 'Summary disclosed a build password.'
        $checked++
    }
}
$baseline = @{WimPath=(Join-Path $fixture 'assets\iso\install.wim');OutputPath=(Join-Path $fixture 'assets\output\negative.qcow2')}
Assert-Throws { & (Join-Path $fixture 'New-ImageConfig.ps1') -WimPath 'C:\does-not-exist.wim' } 'existing Windows'
Assert-Throws { & (Join-Path $fixture 'New-ImageConfig.ps1') @baseline -VirtioIsoPath 'C:\missing.iso' } 'VirtIO ISO'
$chromePath = Join-Path $fixture 'assets\custom-resources\chrome-enterprise64.msi'
Move-Item -LiteralPath $chromePath -Destination ($chromePath+'.held')
Assert-Throws { & (Join-Path $fixture 'New-ImageConfig.ps1') @baseline } 'Required installer'
$skipped = & (Join-Path $fixture 'New-ImageConfig.ps1') @baseline -SkipChrome
Assert-Test (-not $skipped.InstallChrome) 'Skipping a missing optional installer failed.'
Move-Item -LiteralPath ($chromePath+'.held') -Destination $chromePath
$original = [IO.File]::ReadAllText($chromePath)
[IO.File]::WriteAllText($chromePath,'corrupted fixture')
Assert-Throws { & (Join-Path $fixture 'New-ImageConfig.ps1') @baseline } 'signature is not valid'
[IO.File]::WriteAllText($chromePath,$original)
[IO.File]::WriteAllText($baseline.OutputPath,'existing image; preserve')
Assert-Throws { & (Join-Path $fixture 'New-ImageConfig.ps1') @baseline } 'already exists'
Assert-Test ([IO.File]::ReadAllText($baseline.OutputPath) -eq 'existing image; preserve') 'Existing image was changed.'
Assert-Throws { & (Join-Path $fixture 'New-ImageConfig.ps1') -WimPath $baseline.WimPath -ConfigPath (Join-Path $fixture 'public.ini') } 'project local directory'
Assert-Throws { Set-ImageConfigValue -Text "image_name=old" -Key 'image_name' -Value "injected`nimage_path=x" } 'Invalid configuration'
$legacy = Get-GuestSoftwareSelection -ResourceRoot (Join-Path $fixture 'resources')
Assert-Test ($legacy.InstallChrome -and $legacy.InstallVSCode) 'Legacy selection default changed.'
$dataPackages=Join-Path $fixture 'data\custom-resources'
New-Item -ItemType Directory -Path $dataPackages -Force | Out-Null
$dataChrome=Join-Path $dataPackages 'downloaded chrome.msi'
$dataCode=Join-Path $dataPackages 'VSCodeSetup-new-version.exe'
$codePath=Join-Path $fixture 'assets\custom-resources\VSCodeSetup-test.exe'
Copy-Item -LiteralPath $chromePath -Destination $dataChrome
Copy-Item -LiteralPath $codePath -Destination $dataCode
Move-Item -LiteralPath $chromePath -Destination ($chromePath+'.held')
Move-Item -LiteralPath $codePath -Destination ($codePath+'.held')
try {
    $fromData=& (Join-Path $fixture 'New-ImageConfig.ps1') -WimPath $baseline.WimPath -OutputPath (Join-Path $fixture 'assets\output\from-data.qcow2')
    foreach ($entry in @(@{Source=$dataChrome;Staged='chrome-enterprise64.msi'},@{Source=$dataCode;Staged='VSCodeSetup-x64.exe'})) {
        Assert-Test ((Get-FileHash -LiteralPath $entry.Source).Hash -eq (Get-FileHash -LiteralPath (Join-Path $fromData.StagedResources $entry.Staged)).Hash) 'An installer from data/custom-resources was not staged correctly.'
    }
} finally {
    Move-Item -LiteralPath ($chromePath+'.held') -Destination $chromePath
    Move-Item -LiteralPath ($codePath+'.held') -Destination $codePath
}
$script:answers = New-Object 'System.Collections.Generic.Queue[string]'
function Read-Host { param($Prompt) if (-not $script:answers.Count) { throw 'Test input exhausted.' }; return $script:answers.Dequeue() }
$script:answers.Enqueue('bad')
$script:answers.Enqueue('7')
Assert-Test ((Read-BuilderNumber -Prompt 'Test number' -Default 4 -Minimum 1 -Maximum 8) -eq 7) 'Invalid input was not retried.'
$script:answers.Enqueue('Q')
Assert-Throws { Read-BuilderText -Prompt 'Cancel test' } '取消'
& {
    $ProjectRoot=$fixture
    $wimWithSpaces=Join-Path $fixture 'data\iso\Windows image with spaces.wim'
    [IO.File]::WriteAllText($wimWithSpaces,'Source choice fixture; never used to build.')
    $candidates=@(Get-BuilderSourceCandidates -AssetsRoot $fixtureSettings.AssetsRoot)
    Assert-Test ($candidates[0].Path.StartsWith((Join-Path $fixture 'data\iso'))) 'Data sources were not listed first.'
    Assert-Test (@($candidates | Where-Object Path -like '*virtio*').Count -eq 0) 'VirtIO was listed as a Windows installation source.'
    Assert-Test (@($candidates | Where-Object Path -eq $wimWithSpaces).Count -eq 1) 'WIM with spaces was not listed.'
    $duplicate=@(Get-BuilderSourceCandidates -AssetsRoot $fixtureSettings.AssetsRoot -SourcePath $wimWithSpaces)
    Assert-Test ($duplicate.Count -eq $candidates.Count) 'Explicit source duplicated an existing list item.'
    $script:answers.Enqueue('')
    Assert-Test ((Read-BuilderInstallationSource -AssetsRoot $fixtureSettings.AssetsRoot -SourcePath $wimWithSpaces) -eq $wimWithSpaces) 'Explicit source was not the default numbered choice.'
    foreach ($answer in @('0','999','2')) { $script:answers.Enqueue($answer) }
    Assert-Test ((Read-BuilderInstallationSource -AssetsRoot $fixtureSettings.AssetsRoot) -eq $candidates[1].Path) 'Invalid source numbers were not retried.'
    $script:answers.Enqueue([string]($candidates.Count+1))
    $script:answers.Enqueue('C:\missing-source.iso')
    $script:answers.Enqueue('"'+$wimWithSpaces+'"')
    Assert-Test ((Read-BuilderInstallationSource -AssetsRoot $fixtureSettings.AssetsRoot) -eq $wimWithSpaces) 'Manual source choice or quoted path retry failed.'
    $script:answers.Enqueue('Q')
    Assert-Throws { Read-BuilderInstallationSource -AssetsRoot $fixtureSettings.AssetsRoot } '取消'
    $script:answers.Enqueue([string]($candidates.Count+1))
    $script:answers.Enqueue('Q')
    Assert-Throws { Read-BuilderInstallationSource -AssetsRoot $fixtureSettings.AssetsRoot } '取消'
    $ProjectRoot=Join-Path $fixture 'no source candidates'
    $script:answers.Enqueue('')
    $script:answers.Enqueue($wimWithSpaces)
    Assert-Test ((Read-BuilderInstallationSource -AssetsRoot (Join-Path $ProjectRoot 'assets')) -eq $wimWithSpaces) 'Empty source list did not allow manual entry.'
}
Assert-BuilderCapacity -CpuCount '4' -RamBytes '8589934592' -HostCpuCount 32 -HostRamBytes 64GB
Assert-Throws { Assert-BuilderCapacity -CpuCount 33 -RamBytes 8GB -HostCpuCount 32 -HostRamBytes 64GB } 'CPU or memory'
Assert-Throws { Assert-BuilderCapacity -CpuCount 4 -RamBytes 65GB -HostCpuCount 32 -HostRamBytes 64GB } 'CPU or memory'
& {
    $ProjectRoot=$fixture
    $script:configurationCalls=0
    $script:initializationCalls=0
    $script:wizardConfigPaths=New-Object 'System.Collections.Generic.List[string]'
    function Get-BuilderHost { [PSCustomObject]@{Switches=@([PSCustomObject]@{Name='external'});LogicalProcessors=8;MemoryGiB=32} }
    function Initialize-BuilderProject { param($AssetsRoot) $script:initializationCalls++ }
    function Get-ProjectSettings { $fixtureSettings }
    function Get-BuilderSourceImages { param($SourcePath) [PSCustomObject]@{ImageName='Windows 11 Pro for Workstations';ImageIndex=10;ImageVersion='test'} }
    function Initialize-VirtioGuestTools { param($Settings,$VirtioIsoPath,[switch]$RefreshFromIso) }
    function Assert-BuilderDiskSpace { param($OutputPath,$DiskGiB) }
    function Initialize-BuilderTools { throw 'Save-only must not initialize tools.' }
    function Invoke-BuilderAction { throw 'Save-only must not start a build.' }
    function New-BuilderConfiguration {
        param($Parameters)
        Assert-Test ($Parameters.KmsServer -ceq $script:expectedKmsServer) 'Wizard KMS selection did not reach configuration generation.'
        $script:configurationCalls++;$script:wizardConfigPaths.Add($Parameters.ConfigPath)
        [PSCustomObject]@{ConfigPath=$Parameters.ConfigPath}
    }
    foreach ($configureOnly in @($false,$true)) {
        $script:answers.Clear()
        # Assets/source/edition/key defaults, then the KMS choice.
        foreach ($answer in @('','','','')) { $script:answers.Enqueue($answer) }
        $script:expectedKmsServer=Get-PveDefaultKmsServer
        if ($configureOnly) {
            $script:answers.Enqueue('2');$script:answers.Enqueue('')
            $script:expectedKmsServer=''
        } else { $script:answers.Enqueue('') }
        # VirtIO/switch/output/CPU/RAM/disk/timezone defaults, updates/apps false.
        foreach ($answer in @('','','','','','','','N','N','N')) { $script:answers.Enqueue($answer) }
        if (-not $configureOnly) { $script:answers.Enqueue('3') }
        $wizard = Invoke-ImageBuilderWizard -SourcePath (Join-Path $fixture 'assets\iso\Windows.iso') -ConfigureOnly:$configureOnly
        Assert-Test ($wizard.Action -eq '仅保存配置') 'Save-only action changed.'
    }
    Assert-Test ($script:configurationCalls -eq 2) 'Save-only did not generate exactly one configuration per run.'
    Assert-Test (@($script:wizardConfigPaths | Select-Object -Unique).Count -eq 2) 'Separate wizard runs reused the same configuration file.'
    Assert-Test (@($script:wizardConfigPaths | Where-Object { $_ -notlike (Join-Path $fixture 'local\configs\*.ini') }).Count -eq 0) 'Wizard configuration escaped its per-run folder.'
    $script:answers.Clear()
    foreach($answer in @('','','','','','','','','','','','','N','N','N','Q')){$script:answers.Enqueue($answer)}
    Assert-Throws { Invoke-ImageBuilderWizard -SourcePath (Join-Path $fixture 'assets\iso\Windows.iso') } '取消'
    Assert-Test ($script:configurationCalls -eq 2) 'Cancel at the final action still generated a configuration.'
    $callsBefore=$script:initializationCalls
    $script:answers.Clear(); $script:answers.Enqueue('Q')
    Assert-Throws { Invoke-ImageBuilderWizard } '取消'
    Assert-Test ($script:initializationCalls -eq $callsBefore -and $script:configurationCalls -eq 2) 'Cancel continued initialization or configuration.'
}
& {
    $script:switchCreateCalls=0
    $script:adapterQueries=0
    $script:switchTestMode='success'
    function Get-NetAdapter {
        param([switch]$Physical,$ErrorAction)
        $script:adapterQueries++
        if($script:switchTestMode -eq 'no_adapter'){return}
        [PSCustomObject]@{Name='Test Ethernet';InterfaceDescription='Mock physical NIC';LinkSpeed='1 Gbps';Status='Up'}
    }
    function Get-VMSwitch {
        param($Name,$ErrorAction)
        if($Name -eq 'taken'){[PSCustomObject]@{Name='taken';SwitchType='Internal'}}
    }
    function New-VMSwitch {
        param($Name,$NetAdapterName,[bool]$AllowManagementOS,$ErrorAction)
        $script:switchCreateCalls++
        if(-not$AllowManagementOS -or $NetAdapterName -ne 'Test Ethernet'){throw 'Host NIC sharing or adapter selection is incorrect.'}
        if($script:switchTestMode -eq 'failure'){throw 'Simulated switch creation error.'}
        [PSCustomObject]@{Name=$Name;SwitchType='External'}
    }
    $script:answers.Clear()
    $existing=@(Initialize-BuilderExternalSwitches -Switches @([PSCustomObject]@{Name='existing';SwitchType='External'}))
    Assert-Test ($existing[0].Name -eq 'existing' -and $script:adapterQueries -eq 0 -and $script:switchCreateCalls -eq 0) 'An existing switch was modified or prompted.'
    $script:answers.Enqueue('')
    Assert-Throws { Initialize-BuilderExternalSwitches -Switches @() } '未创建'
    Assert-Test ($script:switchCreateCalls -eq 0) 'Default choice created a switch.'
    foreach($answer in @('Y','1','external','N')){$script:answers.Enqueue($answer)}
    Assert-Throws { Initialize-BuilderExternalSwitches -Switches @() } '已取消'
    Assert-Test ($script:switchCreateCalls -eq 0) 'Declining final confirmation created a switch.'
    foreach($answer in @('Y','1','taken','build-external','Y')){$script:answers.Enqueue($answer)}
    $created=Initialize-BuilderExternalSwitches -Switches @()
    Assert-Test ($created.Name -eq 'build-external' -and $script:switchCreateCalls -eq 1) 'Switch creation or duplicate-name retry failed.'
    $script:switchTestMode='no_adapter'
    $script:answers.Enqueue('Y')
    Assert-Throws { Initialize-BuilderExternalSwitches -Switches @() } '物理网卡'
    Assert-Test ($script:switchCreateCalls -eq 1) 'A switch was created with no physical NIC.'
    $script:switchTestMode='failure'
    foreach($answer in @('Y','1','external','Y')){$script:answers.Enqueue($answer)}
    Assert-Throws { Initialize-BuilderExternalSwitches -Switches @() } '创建外部交换机失败'
}
[PSCustomObject]@{SoftwareCombinations=$checked;InputRetry='passed';Cancellation='passed';SaveOnly='passed';NegativeCases='passed';LiteralPaths='passed';DataIsoDiscovery='passed';DataInstallerDiscovery='passed';ExternalSwitchPrompts='passed; network calls mocked';Fixture=$fixture}
& {
    . (Join-Path $root 'scripts\Servicing.Adapter.ps1')
    $script:PveServicingTools=[PSCustomObject]@{DismPath='C:\fixture\dism.exe'}
    $script:PveRunLogDirectory=$fixture
    function Invoke-PveServicingTool {
        param($Executable,[string[]]$Arguments,$Stage)
        Assert-Test ($Arguments.Count -eq 5 -and $Arguments[1] -eq '/Add-Driver') 'DISM argument boundaries were lost.'
        Assert-Test ($Arguments[2] -eq '/driver:Z:\drivers with spaces') 'DISM driver path was split.'
    }
    Add-DriversToImage -winImagePath 'V:\' -driversPath 'Z:\drivers with spaces'
}
